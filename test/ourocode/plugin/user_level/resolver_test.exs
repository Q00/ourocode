defmodule Ourocode.Plugin.UserLevel.ResolverTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.UserLevel.Capability
  alias Ourocode.Plugin.UserLevel.PreflightResult
  alias Ourocode.Plugin.UserLevel.Resolver

  defp superpowers(opts \\ []) do
    {:ok, cap} =
      Capability.new(%{
        plugin_id: "superpowers",
        source: :fixture,
        version: "0.4.2",
        manifest_digest: "sha256:abc",
        trust_scope: Keyword.get(opts, :trust_scope, ["filesystem:read", "filesystem:write"]),
        commands: [
          %{name: "list", aliases: ["ls"], risk_class: "read_only"},
          %{
            name: "test-driven-development",
            aliases: ["tdd"],
            risk_class: "handoff_producing",
            expected_artifacts: [".omx/superpowers/runs/*/seed.md"],
            continuation_hint: "suggest_run"
          }
        ]
      })

    cap
  end

  describe "resolve/2 — unique match" do
    test "exact canonical command match returns :unique_match with confidence :exact" do
      result =
        Resolver.resolve(
          "ooo superpowers test-driven-development --goal retry",
          [superpowers()]
        )

      assert %PreflightResult{
               kind: :unique_match,
               plugin: %Capability{plugin_id: "superpowers"},
               trust_state: :allowed,
               risk_class: :handoff_producing,
               expected_artifacts: [".omx/superpowers/runs/*/seed.md"],
               continuation_policy: :suggest,
               match_explanation: %{matched_by: :canonical, confidence: :exact}
             } = result

      assert result.command.name == "test-driven-development"
      assert result.args == ["--goal", "retry"]
      assert result.reason == nil
    end

    test "alias matches with confidence :alias" do
      result = Resolver.resolve("ooo superpowers tdd --goal x", [superpowers()])

      assert %PreflightResult{
               kind: :unique_match,
               match_explanation: %{matched_by: :alias, confidence: :alias}
             } = result

      assert result.command.name == "test-driven-development"
    end

    test "treats `ouroboros` prefix identically to `ooo`" do
      result =
        Resolver.resolve("ouroboros superpowers tdd --goal x", [superpowers()])

      assert %PreflightResult{kind: :unique_match} = result
    end

    test "preserves argument casing verbatim" do
      result =
        Resolver.resolve(
          "ooo superpowers tdd --Goal MixedCase --Verbose",
          [superpowers()]
        )

      assert %PreflightResult{kind: :unique_match, args: args} = result
      assert "--Goal" in args
      assert "MixedCase" in args
      assert "--Verbose" in args
    end

    test "matches plugin and command case-insensitively even when typed in mixed case" do
      result = Resolver.resolve("OOO Superpowers TDD --goal x", [superpowers()])

      assert %PreflightResult{
               kind: :unique_match,
               match_explanation: %{matched_by: :alias}
             } = result

      assert result.command.name == "test-driven-development"
    end

    test "preserves shell-injection-like arg tokens as argv (no shell parsing)" do
      result =
        Resolver.resolve(
          ~s(ooo superpowers tdd --goal "; rm -rf /"),
          [superpowers()]
        )

      assert result.kind == :unique_match
      # tokenization is whitespace-only; quoting is not honored. The point is
      # that no shell expansion happens here.
      assert "--goal" in result.args
      refute Enum.any?(result.args, &String.contains?(&1, "$("))
    end
  end

  describe "resolve/2 — trust missing" do
    test "capability without trust_scope returns :allowed=false and remediation" do
      result =
        Resolver.resolve(
          "ooo superpowers list",
          [superpowers(trust_scope: [])]
        )

      assert %PreflightResult{
               kind: :unique_match,
               trust_state: :missing,
               remediation: "ouroboros plugin trust superpowers --scope <required-scope>"
             } = result
    end
  end

  describe "resolve/2 — unknown" do
    test "unknown plugin returns :unknown with :unknown_plugin reason" do
      result = Resolver.resolve("ooo unknownplug tdd", [superpowers()])

      assert %PreflightResult{
               kind: :unknown,
               reason: :unknown_plugin,
               plugin: nil,
               command: nil
             } = result
    end

    test "known plugin with unknown command returns :unknown with :unknown_command reason" do
      result = Resolver.resolve("ooo superpowers nope", [superpowers()])

      assert %PreflightResult{
               kind: :unknown,
               reason: :unknown_command,
               plugin: %Capability{plugin_id: "superpowers"},
               command: nil
             } = result
    end

    test "missing command token returns :missing_command_token" do
      result = Resolver.resolve("ooo superpowers", [superpowers()])

      assert %PreflightResult{
               kind: :unknown,
               reason: :missing_command_token,
               plugin: %Capability{plugin_id: "superpowers"}
             } = result
    end

    test "missing plugin token returns :missing_plugin_token" do
      result = Resolver.resolve("ooo", [superpowers()])

      assert %PreflightResult{kind: :unknown, reason: :missing_plugin_token} = result
    end
  end

  describe "resolve/2 — ambiguous" do
    test "duplicate plugin_ids return :ambiguous with candidates" do
      cap_a = superpowers()
      {:ok, cap_b} = Capability.new(%{plugin_id: "superpowers", source: :fixture})

      result = Resolver.resolve("ooo superpowers list", [cap_a, cap_b])

      assert %PreflightResult{
               kind: :ambiguous,
               reason: :duplicate_plugin_ids
             } = result

      assert length(result.candidates) == 2
    end
  end

  describe "resolve/2 — not applicable" do
    test "non-ooo input returns :not_applicable" do
      result = Resolver.resolve("interview some goal", [superpowers()])

      assert %PreflightResult{
               kind: :not_applicable,
               reason: :not_user_level_plugin_input
             } = result
    end

    test "blank input returns :not_applicable" do
      result = Resolver.resolve("   ", [superpowers()])
      assert result.kind == :not_applicable
    end
  end

  describe "applies_to?/2" do
    test "true when ooo + known plugin id" do
      assert Resolver.applies_to?("ooo superpowers list", [superpowers()])
    end

    test "false when ooo + unknown plugin id" do
      refute Resolver.applies_to?("ooo other list", [superpowers()])
    end

    test "false for non-ooo input" do
      refute Resolver.applies_to?("interview x", [superpowers()])
    end

    test "false for blank input" do
      refute Resolver.applies_to?("", [superpowers()])
    end
  end
end
