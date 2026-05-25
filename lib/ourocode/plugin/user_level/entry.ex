defmodule Ourocode.Plugin.UserLevel.Entry do
  @moduledoc """
  Entry point that the runtime calls to decide whether an incoming
  `TaskRequest` should be routed to the UserLevel plugin adapter.

  This is the small router refinement step that keeps
  `Ourocode.Runtime.Router` itself transport- and registry-agnostic:

    * Router does coarse classification (`ooo`/`ouroboros` → ouroboros
      workflow + adapter_route).
    * `Entry.refine/2` looks at the resolved capability list and, if the
      task input targets a known UserLevel plugin, swaps the routing
      decision to `:user_level_plugin` and attaches the plugin_id.

  The runtime call site does:

      task_request
      |> Entry.refine(capabilities)
      |> Dispatcher.dispatch(adapters: adapters, context: context)

  No execution happens here; this is decision data only.
  """

  alias Ourocode.Plugin.UserLevel.Resolver
  alias Ourocode.TaskRequest

  @doc """
  Returns a TaskRequest whose routing_decision is rewritten to
  `:user_level_plugin` when the input targets a known plugin; otherwise
  returns the original TaskRequest unchanged.

  The refined routing_decision carries:

    * `kind` and `execution_route` set to `:user_level_plugin`
    * `runtime_source: :ouroboros`
    * `transport: :auto`
    * `plugin_id` — the matched plugin id
    * `reason: :user_level_plugin_resolved`
  """
  @spec refine(TaskRequest.t(), [Ourocode.Plugin.UserLevel.Capability.t()]) :: TaskRequest.t()
  def refine(%TaskRequest{task_input: input} = task_request, capabilities)
      when is_list(capabilities) do
    if Resolver.applies_to?(input, capabilities) do
      plugin_id = plugin_id_from_input(input)

      routing_decision = %{
        kind: :user_level_plugin,
        execution_route: :user_level_plugin,
        runtime_source: :ouroboros,
        transport: :auto,
        requires_command_syntax?: false,
        advanced_shortcut?: true,
        reason: :user_level_plugin_resolved,
        plugin_id: plugin_id
      }

      %{task_request | routing_decision: routing_decision}
    else
      task_request
    end
  end

  def refine(task_request, _capabilities), do: task_request

  defp plugin_id_from_input(input) do
    input
    |> String.trim()
    |> String.split(~r/\s+/u, trim: true)
    |> case do
      [_prefix, plugin_token | _rest] -> String.downcase(plugin_token)
      _other -> nil
    end
  end
end
