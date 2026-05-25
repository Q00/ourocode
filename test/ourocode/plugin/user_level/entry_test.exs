defmodule Ourocode.Plugin.UserLevel.EntryTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.UserLevel.Capability
  alias Ourocode.Plugin.UserLevel.Entry
  alias Ourocode.TaskRequest

  defp original_routing_decision do
    %{
      kind: :ouroboros_workflow,
      execution_route: :ouroboros_workflow,
      runtime_source: :ouroboros,
      transport: :auto,
      requires_command_syntax?: false,
      advanced_shortcut?: true,
      reason: :explicit_ouroboros_shortcut,
      adapter_route: :workflow
    }
  end

  defp task(input) do
    %TaskRequest{
      id: "tr-#{System.unique_integer([:positive])}",
      source: :cli,
      task_input: input,
      submitted_at_ms: 0,
      routing_decision: original_routing_decision()
    }
  end

  defp superpowers do
    {:ok, capability} =
      Capability.new(%{
        plugin_id: "superpowers",
        source: :fixture,
        trust_scope: ["filesystem:read"],
        commands: [%{name: "list"}]
      })

    capability
  end

  test "rewrites routing_decision to :user_level_plugin when input targets a known plugin" do
    refined = Entry.refine(task("ooo superpowers list"), [superpowers()])

    assert refined.routing_decision == %{
             kind: :user_level_plugin,
             execution_route: :user_level_plugin,
             runtime_source: :ouroboros,
             transport: :auto,
             requires_command_syntax?: false,
             advanced_shortcut?: true,
             reason: :user_level_plugin_resolved,
             plugin_id: "superpowers"
           }
  end

  test "leaves routing_decision unchanged when input is not ooo-shaped" do
    task_request = task("interview goal")
    refined = Entry.refine(task_request, [superpowers()])
    assert refined.routing_decision == task_request.routing_decision
  end

  test "leaves routing_decision unchanged when plugin is unknown" do
    task_request = task("ooo unknown_plugin list")
    refined = Entry.refine(task_request, [superpowers()])
    assert refined.routing_decision == task_request.routing_decision
  end

  test "handles non-list capabilities by returning the task unchanged" do
    task_request = task("ooo superpowers list")
    assert ^task_request = Entry.refine(task_request, nil)
  end
end
