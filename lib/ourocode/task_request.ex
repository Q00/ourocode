defmodule Ourocode.TaskRequest do
  @moduledoc """
  Parser for natural-language task submissions.

  The CLI and dashboard prompt both hand freeform task text to this module. The
  parser intentionally does not require provider-specific or Ouroboros command
  syntax; explicit commands remain possible later as advanced shortcuts, but
  the default path is a plain task request with a deterministic routing
  decision.
  """

  alias Ourocode.Runtime.Router

  defstruct [
    :id,
    :source,
    :task_input,
    :submitted_at_ms,
    :routing_decision,
    external_ids: %{},
    wonder_decisions: []
  ]

  @type routing_decision :: %{
          required(:kind) => :runtime | :ouroboros_workflow | :mcp_flow | :user_level_plugin,
          required(:execution_route) =>
            :runtime | :ouroboros_workflow | :mcp_flow | :user_level_plugin,
          required(:runtime_source) =>
            :auto | :codex | :opencode | :claude_code | :ouroboros | :mcp,
          required(:transport) => :auto | :stdio | :streamable_http | :sse,
          required(:requires_command_syntax?) => false,
          required(:advanced_shortcut?) => boolean(),
          required(:reason) => atom(),
          optional(:adapter_route) => atom(),
          optional(:plugin_id) => String.t()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          source: :cli | :dashboard,
          task_input: String.t(),
          submitted_at_ms: integer(),
          routing_decision: routing_decision(),
          external_ids: map(),
          wonder_decisions: list()
        }

  @config_flags_with_value MapSet.new([
                             "--parallel-child-count",
                             "--repeat-count",
                             "--allowed-memory-growth-mb",
                             "--stale-cleanup-timeout-ms",
                             "--operation-timeout-ms",
                             "--stream-subscription-cleanup-timeout-ms",
                             "--pane-state-retention-ms",
                             "--cleanup-allowed-memory-growth-mb",
                             "--cleanup-stale-cleanup-timeout-ms",
                             "--cleanup-stream-subscription-cleanup-timeout-ms",
                             "--cleanup-pane-state-retention-ms",
                             "--cleanup-policy.allowed-memory-growth-mb",
                             "--cleanup-policy.stale-cleanup-timeout-ms",
                             "--cleanup-policy.stream-subscription-cleanup-timeout-ms",
                             "--cleanup-policy.pane-state-retention-ms"
                           ])

  @doc """
  Parses raw natural-language text into an internal task request.
  """
  @spec parse(String.t(), keyword() | map()) :: {:ok, t()} | {:error, String.t()}
  def parse(input, options \\ [])

  def parse(input, options) when is_binary(input) do
    options = Map.new(options)

    case normalize_task_input(input) do
      "" ->
        {:error, "task input cannot be blank"}

      task_input ->
        {:ok,
         %__MODULE__{
           id: Map.get(options, :id, request_id(task_input)),
           source: Map.get(options, :source, :cli),
           task_input: task_input,
           submitted_at_ms: Map.get(options, :submitted_at_ms, System.system_time(:millisecond)),
           routing_decision: routing_decision(task_input),
           external_ids: %{},
           wonder_decisions: []
         }}
    end
  end

  def parse(_input, _options), do: {:error, "task input must be a string"}

  @doc """
  Splits CLI args into config override args plus an optional natural task request.

  Leading supported config flags are preserved for `Ourocode.Config`. Everything
  after the first non-config token, or after `--`, is treated as freeform task
  text.
  """
  @spec parse_cli_args([String.t()], keyword() | map()) ::
          {:ok, %{config_args: [String.t()], task_request: t() | nil}}
          | {:error, String.t()}
  def parse_cli_args(args, options \\ [])

  def parse_cli_args(args, options) when is_list(args) do
    with {:ok, {config_args, task_args}} <- split_config_args(args) do
      parse_optional_cli_task(config_args, task_args, options)
    end
  end

  def parse_cli_args(_args, _options), do: {:error, "CLI args must be a list"}

  defp parse_optional_cli_task(config_args, [], _options) do
    {:ok, %{config_args: config_args, task_request: nil}}
  end

  defp parse_optional_cli_task(config_args, task_args, options) do
    options =
      options
      |> Map.new()
      |> Map.put_new(:source, :cli)

    with {:ok, task_request} <- parse(Enum.join(task_args, " "), options) do
      {:ok, %{config_args: config_args, task_request: task_request}}
    end
  end

  defp split_config_args(args), do: split_config_args(args, [])

  defp split_config_args([], config_args), do: {:ok, {Enum.reverse(config_args), []}}

  defp split_config_args(["--" | task_args], config_args) do
    {:ok, {Enum.reverse(config_args), task_args}}
  end

  defp split_config_args([arg | rest] = args, config_args) when is_binary(arg) do
    cond do
      config_assignment?(arg) ->
        split_config_args(rest, [arg | config_args])

      MapSet.member?(@config_flags_with_value, arg) ->
        consume_config_value(arg, rest, config_args)

      String.starts_with?(arg, "--") ->
        {:error, "unsupported config override argument: #{arg}"}

      true ->
        {:ok, {Enum.reverse(config_args), args}}
    end
  end

  defp split_config_args([arg | _rest], _config_args) do
    {:error, "CLI args must be strings, got: #{inspect(arg)}"}
  end

  defp consume_config_value(arg, [value | rest], config_args) when is_binary(value) do
    if String.starts_with?(value, "--") do
      {:error, "missing value for config override argument: #{arg}"}
    else
      split_config_args(rest, [value, arg | config_args])
    end
  end

  defp consume_config_value(arg, [], _config_args) do
    {:error, "missing value for config override argument: #{arg}"}
  end

  defp config_assignment?(arg) do
    case String.split(arg, "=", parts: 2) do
      [flag, value] ->
        MapSet.member?(@config_flags_with_value, flag) and String.trim(value) != ""

      _other ->
        false
    end
  end

  defp normalize_task_input(input) do
    input
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
  end

  defp routing_decision(task_input) do
    Router.routing_decision(task_input)
  end

  defp request_id(task_input) do
    :erlang.phash2({task_input, System.unique_integer([:positive, :monotonic])})
    |> Integer.to_string(36)
    |> then(&("task_" <> &1))
  end
end
