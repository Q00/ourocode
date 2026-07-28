defmodule Ourocode.Terminal.HistoryNavigation do
  @moduledoc """
  Pure prompt-history state transitions for the raw TUI.

  Up/Down recall is prefix-filtered: the buffer contents at the moment browsing
  begins become an anchor, and only history entries starting with that anchor
  are visited (fish/zsh `history-search-backward` behaviour). An empty anchor
  matches every entry, so a blank prompt still walks the whole history.
  """

  @spec remember(map(), String.t(), pos_integer()) :: map()
  def remember(state, line, limit) when is_map(state) and is_binary(line) and is_integer(limit) do
    history =
      case List.first(Map.get(state, :history, [])) do
        ^line -> Map.get(state, :history, [])
        _other -> [line | Map.get(state, :history, [])] |> Enum.take(limit)
      end

    %{
      state
      | history: history,
        history_index: 0,
        history_draft: nil,
        history_prefix: nil,
        ooo_cache: nil,
        ooo_cache_loaded_ms: nil
    }
  end

  @spec move(map(), -1 | 1) :: map()
  def move(state, direction) when is_map(state) and direction in [-1, 1] do
    history = Map.get(state, :history, [])
    history_index = Map.get(state, :history_index, 0)

    cond do
      history == [] -> state
      # Not browsing yet and asked to go newer: nothing to restore.
      history_index == 0 and direction == 1 -> state
      true -> step(state, history, history_index, direction)
    end
  end

  @spec reset(map()) :: map()
  def reset(state) when is_map(state),
    do: %{state | history_index: 0, history_draft: nil, history_prefix: nil}

  # Anchor the prefix + draft on the first Up, then reuse them while browsing.
  defp step(state, history, history_index, direction) do
    {prefix, draft} =
      if history_index == 0 do
        buffer = Map.get(state, :buffer, "")
        {buffer, buffer}
      else
        {Map.get(state, :history_prefix) || "", Map.get(state, :history_draft)}
      end

    case find(history, history_index, direction, prefix) do
      {:index, index} ->
        buffer = Enum.at(history, index - 1, "")

        %{
          state
          | history_index: index,
            history_prefix: prefix,
            history_draft: draft,
            buffer: buffer,
            cursor: String.length(buffer)
        }

      :draft ->
        restored = draft || ""

        %{
          state
          | history_index: 0,
            history_prefix: nil,
            history_draft: nil,
            buffer: restored,
            cursor: String.length(restored)
        }

      :none ->
        state
    end
  end

  # Older (-1): the first prefix match below the cursor, or `:none` at the end.
  # Newer (+1): the nearest prefix match above the cursor, else `:draft`.
  defp find(history, history_index, -1, prefix) do
    count = length(history)

    case Enum.find((history_index + 1)..count//1, &matches?(history, &1, prefix)) do
      nil -> :none
      index -> {:index, index}
    end
  end

  defp find(history, history_index, 1, prefix) do
    case Enum.find((history_index - 1)..1//-1, &matches?(history, &1, prefix)) do
      nil -> :draft
      index -> {:index, index}
    end
  end

  defp matches?(history, index, prefix) do
    index >= 1 and String.starts_with?(Enum.at(history, index - 1, ""), prefix)
  end
end
