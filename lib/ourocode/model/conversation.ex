defmodule Ourocode.Model.Conversation do
  @moduledoc """
  Harness-owned multi-turn memory for the direct chat lane.

  Every backend ourocode drives is a one-shot runner — a CLI spawn
  (`claude -p`, `codex exec --ephemeral`, `gemini -p`) or a single Responses
  call with `store: false` — so no backend remembers the previous turn. The
  harness owns the conversation instead: completed exchanges are kept here
  and replayed into the next request. Because the replayed history is plain
  provider-agnostic text, it survives switching models mid-conversation.

  Token economy mirrors the interview router's observation pruning: each
  stored reply is capped, and rendering keeps the newest turns inside a byte
  budget while older turns collapse into one elision marker.
  """

  @turn_cap_bytes 4_096
  @history_budget_bytes 16_384
  @max_turns_kept 100

  @type turn :: %{user: String.t(), assistant: String.t()}
  @type t :: %__MODULE__{turns: [turn()]}

  defstruct turns: []

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{turns: turns}), do: turns == []

  @doc "Appends a completed user/assistant exchange (each side byte-capped)."
  @spec add_turn(t(), String.t(), String.t()) :: t()
  def add_turn(%__MODULE__{turns: turns} = conversation, user, assistant)
      when is_binary(user) and is_binary(assistant) do
    turns = turns ++ [%{user: cap(user), assistant: cap(assistant)}]
    %{conversation | turns: Enum.take(turns, -@max_turns_kept)}
  end

  @doc "Serializes turns to JSON-ready maps for persistence."
  @spec to_list(t()) :: [map()]
  def to_list(%__MODULE__{turns: turns}) do
    Enum.map(turns, fn %{user: user, assistant: assistant} ->
      %{"user" => user, "assistant" => assistant}
    end)
  end

  @doc "Rebuilds a conversation from `to_list/1` output; junk entries drop."
  @spec from_list(term()) :: t()
  def from_list(entries) when is_list(entries) do
    turns =
      Enum.flat_map(entries, fn
        %{"user" => user, "assistant" => assistant}
        when is_binary(user) and is_binary(assistant) ->
          [%{user: user, assistant: assistant}]

        _junk ->
          []
      end)

    %__MODULE__{turns: Enum.take(turns, -@max_turns_kept)}
  end

  def from_list(_entries), do: new()

  @doc """
  Renders the prompt a one-shot CLI backend should receive: the budgeted
  transcript followed by the current message. With no history the prompt
  passes through byte-identical, so first turns keep today's behaviour.
  """
  @spec render_prompt(t(), String.t()) :: String.t()
  def render_prompt(%__MODULE__{turns: []}, prompt), do: prompt

  def render_prompt(%__MODULE__{} = conversation, prompt) do
    {turns, elided} = budgeted_turns(conversation)

    transcript =
      Enum.map_join(turns, "\n\n", fn %{user: user, assistant: assistant} ->
        "user: #{normalize_newlines(user)}\nassistant: #{normalize_newlines(assistant)}"
      end)

    elision = if elided > 0, do: "[#{elided} earlier turn(s) elided]\n\n", else: ""

    IO.iodata_to_binary([
      "## Conversation so far (replayed by the ourocode harness)\n",
      elision,
      transcript,
      "\n\n## Current message\n",
      normalize_newlines(prompt),
      "\n"
    ])
  end

  @doc """
  Builds the Responses API `input` items for the same budgeted history:
  alternating user/assistant messages ending with the current prompt.
  """
  @spec input_items(t(), String.t()) :: [map()]
  def input_items(%__MODULE__{} = conversation, prompt) do
    {turns, _elided} = budgeted_turns(conversation)

    history =
      Enum.flat_map(turns, fn %{user: user, assistant: assistant} ->
        [
          input_item("user", "input_text", user),
          input_item("assistant", "output_text", assistant)
        ]
      end)

    history ++ [input_item("user", "input_text", prompt)]
  end

  defp input_item(role, type, text),
    do: %{"role" => role, "content" => [%{"type" => type, "text" => text}]}

  @doc """
  The budgeted history as `{user, assistant}` tuples, for providers that
  build their own message shape (e.g. the Anthropic Messages API).
  """
  @spec budgeted_pairs(t()) :: [{String.t(), String.t()}]
  def budgeted_pairs(%__MODULE__{} = conversation) do
    {turns, _elided} = budgeted_turns(conversation)
    Enum.map(turns, fn %{user: user, assistant: assistant} -> {user, assistant} end)
  end

  # Newest-first walk under the byte budget; the newest turn always survives
  # and the walk halts at the first turn that no longer fits, so the kept
  # history is always a contiguous recent window.
  defp budgeted_turns(%__MODULE__{turns: turns}) do
    {kept, _used} =
      turns
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn turn, {kept, used} ->
        size = byte_size(turn.user) + byte_size(turn.assistant)

        if kept == [] or used + size <= @history_budget_bytes do
          {:cont, {[turn | kept], used + size}}
        else
          {:halt, {kept, used}}
        end
      end)

    {kept, length(turns) - length(kept)}
  end

  defp cap(text) when byte_size(text) <= @turn_cap_bytes, do: text

  defp cap(text) do
    utf8_prefix(text, @turn_cap_bytes) <> "\n...[truncated]"
  end

  defp normalize_newlines(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  # A byte cut lands at most 3 bytes inside a UTF-8 sequence; after that the
  # content was not valid UTF-8 to begin with and is kept as cut.
  defp utf8_prefix(bin, limit), do: trim_invalid(binary_part(bin, 0, limit), 3)

  defp trim_invalid(part, attempts_left) when attempts_left < 0 or byte_size(part) == 0,
    do: part

  defp trim_invalid(part, attempts_left) do
    if String.valid?(part) do
      part
    else
      trim_invalid(binary_part(part, 0, byte_size(part) - 1), attempts_left - 1)
    end
  end
end
