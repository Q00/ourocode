defmodule Ourocode.Runtime.UserLevelPluginInvocation do
  @moduledoc """
  Runtime adapter for `:user_level_plugin` execution routes.

  Takes a `TaskRequest` whose routing decision references an installed
  Ouroboros UserLevel plugin, resolves the request against a capability
  list, and dispatches the matched command through the guarded external
  command runner installed by `Ourocode.Runtime.Dispatcher`.

  Safety rules (the entire point of this module):

    * The adapter never executes anything when the preflight result is not
      `:unique_match`. Ambiguous, unknown, or not-applicable results return
      a structured error.
    * The adapter never executes when `trust_state` is anything other than
      `:allowed`. The structured error includes the remediation string so
      the UI can render it verbatim.
    * The adapter never executes commands whose declared `risk_class` is
      `:destructive` unless the dispatch context explicitly carries
      `destructive_action_approved?: true`. Future trust UX can flip this
      flag; until then destructive actions are blocked closed.
    * Arguments are passed through as an argv list (never assembled into a
      shell string). The Dispatcher's `guarded_external_command_runner`
      enforces the forbidden-command rules regardless.

  Context inputs (all optional unless noted):

    * `:capabilities` (required) — list of `Ourocode.Plugin.UserLevel.Capability`
      structs. The adapter resolves against this snapshot rather than
      reaching into a live registry, so unit tests can pass fixture data.
    * `:external_command_runner` (set by Dispatcher) — guarded runner the
      adapter must use.
    * `:cwd` — working directory passed to the runner.
    * `:env` — environment overlay for the runner.
    * `:command` — override the executable name (defaults to `"ouroboros"`).
    * `:destructive_action_approved?` — explicit approval flag for
      destructive risk_class commands.

  Result envelope:

    %{
      type: :user_level_plugin_invocation,
      status: :invoked | :blocked,
      task_request_id: String.t(),
      preflight: PreflightResult.t(),
      argv: [String.t()],
      command: String.t(),
      execution: %{...} | nil,
      blocked_reason: atom() | nil
    }
  """

  @behaviour Ourocode.Runtime.Adapter

  alias Ourocode.Plugin.UserLevel.Capability
  alias Ourocode.Plugin.UserLevel.PreflightResult
  alias Ourocode.Plugin.UserLevel.Resolver
  alias Ourocode.TaskRequest

  @default_command "ouroboros"

  @type invocation :: %{
          required(:type) => :user_level_plugin_invocation,
          required(:status) => :invoked | :blocked,
          required(:task_request_id) => String.t(),
          required(:preflight) => PreflightResult.t(),
          required(:argv) => [String.t()],
          required(:command) => String.t(),
          optional(:execution) => map(),
          optional(:blocked_reason) => atom()
        }

  @impl true
  @spec execute(TaskRequest.t(), map()) :: {:ok, invocation()} | {:error, term()}
  def execute(%TaskRequest{} = task_request, context) when is_map(context) do
    with {:ok, capabilities} <- fetch_capabilities(context),
         %PreflightResult{} = preflight <-
           Resolver.resolve(task_request.task_input, capabilities) do
      preflight
      |> evaluate(context)
      |> finalize(task_request, preflight, context)
    end
  end

  def execute(_task_request, _context), do: {:error, :invalid_task_request}

  defp fetch_capabilities(context) do
    case Map.get(context, :capabilities) do
      capabilities when is_list(capabilities) ->
        if Enum.all?(capabilities, &match?(%Capability{}, &1)) do
          {:ok, capabilities}
        else
          {:error, :invalid_capabilities_in_context}
        end

      nil ->
        {:error, :capabilities_required_in_context}

      _other ->
        {:error, :invalid_capabilities_in_context}
    end
  end

  defp evaluate(%PreflightResult{kind: :unique_match} = preflight, context) do
    cond do
      preflight.trust_state != :allowed ->
        {:blocked, :trust_missing}

      preflight.risk_class == :destructive and
          Map.get(context, :destructive_action_approved?) != true ->
        {:blocked, :destructive_action_requires_approval}

      true ->
        :allowed
    end
  end

  defp evaluate(%PreflightResult{kind: :ambiguous}, _context), do: {:blocked, :ambiguous_match}
  defp evaluate(%PreflightResult{kind: :unknown}, _context), do: {:blocked, :unknown_plugin_or_command}

  defp evaluate(%PreflightResult{kind: :not_applicable}, _context),
    do: {:blocked, :not_user_level_plugin_input}

  defp finalize({:blocked, reason}, task_request, preflight, context) do
    {:ok,
     %{
       type: :user_level_plugin_invocation,
       status: :blocked,
       task_request_id: to_string(task_request.id),
       preflight: preflight,
       argv: argv_for(preflight, context),
       command: command_for(context),
       blocked_reason: reason
     }}
  end

  defp finalize(:allowed, task_request, preflight, context) do
    argv = argv_for(preflight, context)
    command = command_for(context)
    runner = Map.get(context, :external_command_runner)

    cond do
      runner == nil ->
        {:error, :external_command_runner_not_configured}

      not is_function(runner, 3) ->
        {:error, :invalid_external_command_runner}

      true ->
        case runner.(command, argv, runner_opts(context)) do
          {:ok, execution} ->
            {:ok,
             %{
               type: :user_level_plugin_invocation,
               status: :invoked,
               task_request_id: to_string(task_request.id),
               preflight: preflight,
               argv: argv,
               command: command,
               execution: execution
             }}

          {:error, reason} ->
            {:ok,
             %{
               type: :user_level_plugin_invocation,
               status: :blocked,
               task_request_id: to_string(task_request.id),
               preflight: preflight,
               argv: argv,
               command: command,
               blocked_reason: {:external_command_failed, reason}
             }}
        end
    end
  end

  defp argv_for(%PreflightResult{kind: :unique_match, plugin: plugin, command: command, args: args}, _context) do
    [plugin.plugin_id, command.name | args]
  end

  defp argv_for(_preflight, _context), do: []

  defp command_for(context), do: Map.get(context, :command, @default_command)

  defp runner_opts(context) do
    context
    |> Map.take([:cwd, :env, :timeout_ms])
    |> Map.new()
  end
end
