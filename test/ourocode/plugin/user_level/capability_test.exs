defmodule Ourocode.Plugin.UserLevel.CapabilityTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.UserLevel.Capability
  alias Ourocode.Plugin.UserLevel.Capability.Command, as: CommandCapability

  describe "new/1" do
    test "builds a capability from a minimal valid descriptor" do
      assert {:ok, %Capability{} = capability} =
               Capability.new(%{plugin_id: "superpowers", source: :ouroboros_cli})

      assert capability.plugin_id == "superpowers"
      assert capability.plugin_name == "superpowers"
      assert capability.source == :ouroboros_cli
      assert capability.commands == []
      assert capability.trust_scope == []
      assert capability.install_scope == :unknown
      assert %DateTime{} = capability.discovered_at
    end

    test "normalizes commands and drops invalid ones" do
      assert {:ok, capability} =
               Capability.new(%{
                 plugin_id: "superpowers",
                 source: :ouroboros_cli,
                 commands: [
                   %{name: "list"},
                   %{name: ""},
                   %{name: "tdd", aliases: ["test-driven-development"]}
                 ]
               })

      assert [%CommandCapability{name: "list"}, %CommandCapability{name: "tdd"} = tdd] =
               capability.commands

      assert tdd.aliases == ["test-driven-development"]
    end

    test "rejects missing plugin_id" do
      assert {:error, :invalid_capability_attrs} =
               Capability.new(%{source: :ouroboros_cli})
    end

    test "rejects unknown source" do
      assert {:error, :invalid_capability_attrs} =
               Capability.new(%{plugin_id: "x", source: :random})
    end

    test "uses caller-provided discovered_at when present" do
      stamp = ~U[2026-01-01 00:00:00Z]

      assert {:ok, capability} =
               Capability.new(%{
                 plugin_id: "superpowers",
                 source: :fixture,
                 discovered_at: stamp
               })

      assert capability.discovered_at == stamp
    end

    test "trust_scope drops blanks and dedupes" do
      assert {:ok, capability} =
               Capability.new(%{
                 plugin_id: "x",
                 source: :ouroboros_cli,
                 trust_scope: ["filesystem:read", "", "filesystem:read", "filesystem:write"]
               })

      assert capability.trust_scope == ["filesystem:read", "filesystem:write"]
    end
  end

  describe "identity/1" do
    test "is stable when plugin_id, version, and manifest_digest match" do
      attrs = %{
        plugin_id: "superpowers",
        source: :ouroboros_cli,
        version: "0.4.2",
        manifest_digest: "sha256:abc"
      }

      {:ok, a} = Capability.new(attrs)
      {:ok, b} = Capability.new(attrs)

      assert Capability.identity(a) == Capability.identity(b)
      assert Capability.identity(a) == {"superpowers", "0.4.2", "sha256:abc"}
    end

    test "differs when manifest digest changes" do
      {:ok, a} =
        Capability.new(%{
          plugin_id: "superpowers",
          source: :ouroboros_cli,
          manifest_digest: "sha256:old"
        })

      {:ok, b} =
        Capability.new(%{
          plugin_id: "superpowers",
          source: :ouroboros_cli,
          manifest_digest: "sha256:new"
        })

      refute Capability.identity(a) == Capability.identity(b)
    end
  end

  describe "find_command/2" do
    setup do
      {:ok, capability} =
        Capability.new(%{
          plugin_id: "superpowers",
          source: :fixture,
          commands: [
            %{name: "list"},
            %{name: "test-driven-development", aliases: ["tdd"]}
          ]
        })

      %{capability: capability}
    end

    test "matches canonical name", %{capability: capability} do
      assert %CommandCapability{name: "test-driven-development"} =
               Capability.find_command(capability, "test-driven-development")
    end

    test "matches alias", %{capability: capability} do
      assert %CommandCapability{name: "test-driven-development"} =
               Capability.find_command(capability, "tdd")
    end

    test "returns nil for unknown command", %{capability: capability} do
      assert nil == Capability.find_command(capability, "nope")
    end
  end
end
