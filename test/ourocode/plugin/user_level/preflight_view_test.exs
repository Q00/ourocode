defmodule Ourocode.Plugin.UserLevel.PreflightViewTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.UserLevel.Capability
  alias Ourocode.Plugin.UserLevel.PreflightResult
  alias Ourocode.Plugin.UserLevel.PreflightView
  alias Ourocode.Plugin.UserLevel.Resolver

  defp superpowers do
    {:ok, capability} =
      Capability.new(%{
        plugin_id: "superpowers",
        source: :fixture,
        version: "0.4.2",
        trust_scope: ["filesystem:read"],
        commands: [
          %{
            name: "test-driven-development",
            aliases: ["tdd"],
            risk_class: "handoff_producing",
            expected_artifacts: [".omx/superpowers/runs/*/seed.md"],
            continuation_hint: "suggest_run"
          },
          %{name: "list", risk_class: "read_only"}
        ]
      })

    capability
  end

  test "projects a unique_match into a JSON-safe map with trust + side effects" do
    result = Resolver.resolve("ooo superpowers tdd --goal x", [superpowers()])

    view = PreflightView.project(result)

    assert view.kind == :unique_match
    assert view.plugin.plugin_id == "superpowers"
    assert view.command.name == "test-driven-development"
    assert view.args == ["--goal", "x"]
    assert view.trust.state == :allowed
    assert view.trust.remediation == nil
    assert view.side_effects.execution == :pending_approval
    assert view.side_effects.discovery == :read_only
    assert view.side_effects.risk_class == :handoff_producing

    assert view.side_effects.expected_artifacts == [
             ".omx/superpowers/runs/*/seed.md"
           ]

    assert view.side_effects.continuation_policy == :suggest
    assert view.candidates == []
    assert view.match_explanation == %{matched_by: :alias, confidence: :alias}
  end

  test "projects trust missing into remediation" do
    {:ok, capability} =
      Capability.new(%{
        plugin_id: "superpowers",
        source: :fixture,
        trust_scope: [],
        commands: [%{name: "list", risk_class: "read_only"}]
      })

    result = Resolver.resolve("ooo superpowers list", [capability])
    view = PreflightView.project(result)

    assert view.trust.state == :missing
    assert view.trust.remediation =~ "ouroboros plugin trust"
    assert view.side_effects.execution == :pending_approval
  end

  test "projects ambiguous candidates" do
    a = superpowers()
    {:ok, b} = Capability.new(%{plugin_id: "superpowers", source: :fixture})

    result = Resolver.resolve("ooo superpowers list", [a, b])
    view = PreflightView.project(result)

    assert view.kind == :ambiguous
    assert length(view.candidates) == 2
    assert view.side_effects.execution == :blocked
  end

  test "projects not_applicable inputs with execution :blocked" do
    result = %PreflightResult{
      kind: :not_applicable,
      task_input: "hello"
    }

    view = PreflightView.project(result)
    assert view.kind == :not_applicable
    assert view.side_effects.execution == :blocked
  end
end
