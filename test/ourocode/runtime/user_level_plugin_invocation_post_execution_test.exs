defmodule Ourocode.Runtime.UserLevelPluginInvocationPostExecutionTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.UserLevel.Capability
  alias Ourocode.Runtime.UserLevelPluginInvocation
  alias Ourocode.TaskRequest

  setup do
    tmp = Path.join(System.tmp_dir!(), "ourocode_invocation_post_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{cwd: tmp}
  end

  defp superpowers_capability do
    {:ok, capability} =
      Capability.new(%{
        plugin_id: "superpowers",
        source: :fixture,
        trust_scope: ["filesystem:read", "filesystem:write"],
        commands: [
          %{
            name: "tdd",
            risk_class: "handoff_producing",
            expected_artifacts: [".omx/superpowers/runs/*/seed.md"],
            continuation_hint: "suggest_run"
          }
        ]
      })

    capability
  end

  defp task(input) do
    %TaskRequest{
      id: "tr-#{System.unique_integer([:positive])}",
      source: :cli,
      task_input: input,
      submitted_at_ms: 0,
      routing_decision: %{
        kind: :user_level_plugin,
        execution_route: :user_level_plugin,
        runtime_source: :ouroboros,
        transport: :auto,
        requires_command_syntax?: false,
        advanced_shortcut?: true,
        reason: :user_level_plugin_resolved,
        plugin_id: "superpowers"
      }
    }
  end

  defp write_seed(cwd) do
    seed = Path.join([cwd, ".omx", "superpowers", "runs", "abc", "seed.md"])
    seed |> Path.dirname() |> File.mkdir_p!()
    File.write!(seed, "# seed\n")
    seed
  end

  test "attaches discovered artifacts and a :suggest continuation to the envelope",
       %{cwd: cwd} do
    seed = write_seed(cwd)

    runner = fn _cmd, _argv, _opts ->
      {:ok, %{status: 0, stdout: "", stderr: ""}}
    end

    assert {:ok, envelope} =
             UserLevelPluginInvocation.execute(task("ooo superpowers tdd --goal x"), %{
               capabilities: [superpowers_capability()],
               external_command_runner: runner,
               cwd: cwd
             })

    assert envelope.status == :invoked

    assert [%{kind: :seed, path: ^seed}] = envelope.artifacts
    assert envelope.continuation.action == :suggest
    assert envelope.continuation.seed_path == seed

    assert envelope.continuation.command_template ==
             "ooo run seed_path=#{seed}"
  end

  test "auto_run continuation when prompt opts in explicitly", %{cwd: cwd} do
    write_seed(cwd)
    runner = fn _cmd, _argv, _opts -> {:ok, %{status: 0, stdout: "", stderr: ""}} end

    {:ok, envelope} =
      UserLevelPluginInvocation.execute(
        task("ooo superpowers tdd --goal x then run the generated handoff"),
        %{
          capabilities: [superpowers_capability()],
          external_command_runner: runner,
          cwd: cwd
        }
      )

    assert envelope.continuation.action == :auto_run
  end

  test "decision journal callback receives preflight + dispatch + artifact + continuation events",
       %{cwd: cwd} do
    write_seed(cwd)
    runner = fn _cmd, _argv, _opts -> {:ok, %{status: 0, stdout: "", stderr: ""}} end

    pid = self()
    journal = fn event -> send(pid, {:journal, event["event_type"]}); :ok end

    {:ok, _envelope} =
      UserLevelPluginInvocation.execute(task("ooo superpowers tdd --goal x"), %{
        capabilities: [superpowers_capability()],
        external_command_runner: runner,
        cwd: cwd,
        decision_journal: journal
      })

    assert_received {:journal, "user_level_preflight"}
    assert_received {:journal, "user_level_dispatch"}
    assert_received {:journal, "user_level_artifact"}
    assert_received {:journal, "user_level_continuation"}
  end

  test "blocked dispatch still records preflight and dispatch journal events",
       %{cwd: cwd} do
    runner = fn _cmd, _argv, _opts -> flunk("must not run when trust missing") end

    {:ok, untrusted} =
      Capability.new(%{
        plugin_id: "superpowers",
        source: :fixture,
        trust_scope: [],
        commands: [%{name: "tdd", risk_class: "handoff_producing"}]
      })

    pid = self()
    journal = fn event -> send(pid, {:journal, event["event_type"]}); :ok end

    {:ok, envelope} =
      UserLevelPluginInvocation.execute(task("ooo superpowers tdd --goal x"), %{
        capabilities: [untrusted],
        external_command_runner: runner,
        cwd: cwd,
        decision_journal: journal
      })

    assert envelope.status == :blocked
    assert envelope.blocked_reason == :trust_missing

    assert_received {:journal, "user_level_preflight"}
    assert_received {:journal, "user_level_dispatch"}
    refute_received {:journal, "user_level_artifact"}
    refute_received {:journal, "user_level_continuation"}
  end
end
