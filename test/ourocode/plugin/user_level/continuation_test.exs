defmodule Ourocode.Plugin.UserLevel.ContinuationTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.UserLevel.Capability.Command, as: CommandCapability
  alias Ourocode.Plugin.UserLevel.Continuation
  alias Ourocode.Plugin.UserLevel.PreflightResult

  defp preflight(opts \\ []) do
    risk = Keyword.get(opts, :risk_class, :handoff_producing)
    hint = Keyword.get(opts, :continuation_hint, :suggest_run)

    {:ok, command} =
      CommandCapability.new(%{
        name: "tdd",
        risk_class: Atom.to_string(risk),
        continuation_hint: Atom.to_string(hint),
        expected_artifacts: [".omx/runs/*/seed.md"]
      })

    %PreflightResult{
      kind: :unique_match,
      task_input: Keyword.get(opts, :task_input, "ooo superpowers tdd --goal x"),
      command: command,
      risk_class: risk,
      expected_artifacts: command.expected_artifacts,
      continuation_policy: :suggest
    }
  end

  defp seed_artifact(path \\ "/tmp/runs/x/seed.md") do
    %{kind: :seed, path: path, glob: ".omx/runs/*/seed.md"}
  end

  describe "decide/2 — auto-run intent" do
    test "auto-runs when prompt asks 'then run the generated handoff'" do
      result =
        Continuation.decide(
          preflight(task_input: "ooo superpowers tdd --goal x then run the generated handoff"),
          [seed_artifact()]
        )

      assert result.action == :auto_run
      assert result.seed_path == "/tmp/runs/x/seed.md"
      assert result.command_template == "ooo run seed_path=/tmp/runs/x/seed.md"
      assert result.reason == :auto_run_requested
    end

    test "auto-runs for Korean opt-in phrase" do
      result =
        Continuation.decide(
          preflight(task_input: "ooo superpowers tdd --goal x 이어서 실행"),
          [seed_artifact()]
        )

      assert result.action == :auto_run
    end

    test "does not auto-run without an explicit opt-in phrase" do
      result =
        Continuation.decide(preflight(), [seed_artifact()])

      assert result.action == :suggest
      assert result.command_template == "ooo run seed_path=/tmp/runs/x/seed.md"
      assert result.reason == :user_confirmation_required
    end
  end

  describe "decide/2 — risk class gating" do
    test "read_only commands never continue" do
      result =
        Continuation.decide(
          preflight(
            risk_class: :read_only,
            task_input: "ooo superpowers list then run the generated handoff"
          ),
          [seed_artifact()]
        )

      assert result.action == :none
      assert result.reason == :read_only_command
    end

    test "destructive commands never auto-run, even when opt-in is present" do
      result =
        Continuation.decide(
          preflight(
            risk_class: :destructive,
            task_input: "ooo danger wipe then run the generated handoff"
          ),
          [seed_artifact()]
        )

      assert result.action == :suggest
      assert result.reason == :destructive_requires_explicit_approval
    end
  end

  describe "decide/2 — no continuation artifact" do
    test "no seed artifact returns :none with :no_continuation_artifact reason" do
      result = Continuation.decide(preflight(), [])
      assert result.action == :none
      assert result.reason == :no_continuation_artifact
    end

    test "only handoff (no seed) still returns :none" do
      handoff = %{kind: :handoff, path: "/tmp/handoff.md", glob: ".omx/runs/*/handoff.md"}
      result = Continuation.decide(preflight(), [handoff])
      assert result.action == :none
    end
  end

  describe "decide/2 — non-unique_match" do
    test "ambiguous preflight returns :none" do
      result = Continuation.decide(%PreflightResult{kind: :ambiguous}, [seed_artifact()])
      assert result.action == :none
    end
  end

  describe "auto_run_requested?/1" do
    test "true for English opt-in" do
      assert Continuation.auto_run_requested?("anything then run the seed please")
    end

    test "true for Korean opt-in" do
      assert Continuation.auto_run_requested?("실험 후 이후 실행")
    end

    test "false for unrelated text" do
      refute Continuation.auto_run_requested?("just run the plugin")
    end
  end
end
