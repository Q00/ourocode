defmodule Ourocode.Plugin.UserLevel.RegistryEntryTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.UserLevel.Capability
  alias Ourocode.Plugin.UserLevel.RegistryEntry

  defp capability(opts \\ []) do
    {:ok, capability} =
      Capability.new(%{
        plugin_id: Keyword.get(opts, :plugin_id, "superpowers"),
        source: :ouroboros_cli,
        version: Keyword.get(opts, :version, "0.4.2"),
        manifest_digest: Keyword.get(opts, :manifest_digest, "sha256:abc"),
        trust_scope: Keyword.get(opts, :trust_scope, []),
        commands: [
          %{
            name: "test-driven-development",
            aliases: ["tdd"],
            summary: "TDD handoff.",
            args: [%{name: "goal", required: true, description: "User goal."}],
            risk_class: "handoff_producing",
            expected_artifacts: [".omx/superpowers/runs/*/seed.md"],
            continuation_hint: "suggest_run"
          }
        ]
      })

    capability
  end

  test "projects one entry per command capability" do
    [entry] = RegistryEntry.entries(capability())

    assert entry.id == "user_level_plugin:superpowers:test-driven-development"
    assert entry.name == "superpowers test-driven-development"
    assert entry.slash == "/superpowers test-driven-development"
    assert entry.aliases == ["/superpowers tdd"]
    assert entry.source == :plugin
    assert entry.source_id == "superpowers"
    assert entry.category == :plugins
    assert entry.summary == "TDD handoff."
    assert entry.availability == :available
    assert entry.runnable? == true

    assert entry.args == [%{name: "goal", required?: true, description: "User goal."}]

    assert entry.run_spec.kind == :user_level_plugin_command
    assert entry.run_spec.plugin_id == "superpowers"
    assert entry.run_spec.command == "test-driven-development"
    assert entry.run_spec.risk_class == :handoff_producing
    assert entry.run_spec.continuation_hint == :suggest_run

    assert entry.metadata.plugin_id == "superpowers"
    assert entry.metadata.plugin_surface == :user_level
    assert entry.metadata.namespace_owner == :ouroboros
    assert entry.metadata.capability_version == "0.4.2"
    assert entry.metadata.manifest_digest == "sha256:abc"
  end

  test "trust metadata defaults to requires_explicit_approval when no scopes are present" do
    [entry] = RegistryEntry.entries(capability(trust_scope: []))

    assert entry.metadata.trust_policy == %{
             "tier" => "user_level",
             "requires_explicit_approval" => true
           }

    assert entry.metadata.trust_evaluation == %{
             "trusted" => false,
             "trust_scopes" => []
           }
  end

  test "trust metadata reflects discovered trust scopes" do
    scopes = ["filesystem:read", "filesystem:write"]
    [entry] = RegistryEntry.entries(capability(trust_scope: scopes))

    assert entry.metadata.trust_policy == %{
             "tier" => "user_level",
             "requires_explicit_approval" => false,
             "trust_scopes" => scopes
           }

    assert entry.metadata.trust_evaluation == %{
             "trusted" => true,
             "trust_scopes" => scopes
           }
  end

  test "entries/1 flattens a list of capabilities" do
    one = capability(plugin_id: "a", manifest_digest: "sha256:a")
    two = capability(plugin_id: "b", manifest_digest: "sha256:b")

    entries = RegistryEntry.entries([one, two])
    assert length(entries) == 2
    assert Enum.map(entries, & &1.source_id) == ["a", "b"]
  end
end
