defmodule Ourocode.Plugin.UserLevel.Discovery.OuroborosCLITest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.UserLevel.Discovery.OuroborosCLI

  @fixture_path Path.join([__DIR__, "..", "..", "..", "..", "fixtures", "user_level_plugins", "superpowers.json"])

  test "parses the superpowers fixture into four commands" do
    json = File.read!(@fixture_path)

    assert {:ok, [plugin]} = OuroborosCLI.parse(json)

    assert plugin.plugin_id == "superpowers"
    assert plugin.version == "0.4.2"
    assert plugin.install_scope == :user
    assert plugin.trust_scope == ["filesystem:read", "filesystem:write"]
    assert plugin.manifest_digest == "sha256:abc123def456"

    names = Enum.map(plugin.commands, & &1.name)
    assert names == ["list", "inspect", "test-driven-development", "systematic-debugging"]

    tdd = Enum.find(plugin.commands, &(&1.name == "test-driven-development"))
    assert tdd.aliases == ["tdd"]
    assert tdd.risk_class == "handoff_producing"

    assert tdd.expected_artifacts == [
             ".omx/superpowers/runs/*/seed.md",
             ".omx/superpowers/runs/*/handoff.md"
           ]
  end

  test "treats a bare JSON array (no plugins wrapper) the same way" do
    json = ~s([{"id":"x","name":"x","commands":[]}])
    assert {:ok, [plugin]} = OuroborosCLI.parse(json)
    assert plugin.plugin_id == "x"
  end

  test "rejects malformed JSON" do
    assert {:error, {:ouroboros_cli_invalid_json, _}} =
             OuroborosCLI.parse("not-json")
  end

  test "rejects unexpected JSON shape" do
    assert {:error, :ouroboros_cli_unexpected_shape} =
             OuroborosCLI.parse(~s({"unexpected": true}))
  end

  test "runner failure surfaces as command_failed" do
    runner = fn _cmd, _args, _opts ->
      {:ok, %{status: 1, stdout: "", stderr: "ouroboros: not found"}}
    end

    assert {:error, {:ouroboros_cli_failed, %{exit_status: 1, stderr: "ouroboros: not found"}}} =
             OuroborosCLI.discover(command_runner: runner)
  end

  test "runner error surfaces as unavailable" do
    runner = fn _cmd, _args, _opts -> {:error, :enoent} end

    assert {:error, {:ouroboros_cli_unavailable, :enoent}} =
             OuroborosCLI.discover(command_runner: runner)
  end

  test "happy path runner returns parsed descriptors" do
    json = File.read!(@fixture_path)
    runner = fn _cmd, _args, _opts -> {:ok, %{status: 0, stdout: json, stderr: ""}} end

    assert {:ok, [plugin]} = OuroborosCLI.discover(command_runner: runner)
    assert plugin.plugin_id == "superpowers"
  end
end
