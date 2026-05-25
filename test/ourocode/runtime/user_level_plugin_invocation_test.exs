defmodule Ourocode.Runtime.UserLevelPluginInvocationTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.UserLevel.Capability
  alias Ourocode.Plugin.UserLevel.Discovery.OuroborosCLI
  alias Ourocode.Plugin.UserLevel.PreflightResult
  alias Ourocode.Runtime.UserLevelPluginInvocation
  alias Ourocode.TaskRequest

  @fixture_path Path.join([__DIR__, "..", "..", "fixtures", "user_level_plugins", "superpowers.json"])

  defp superpowers_capability!(opts \\ []) do
    json = File.read!(@fixture_path)
    {:ok, [raw]} = OuroborosCLI.parse(json)

    raw =
      raw
      |> Map.put(:trust_scope, Keyword.get(opts, :trust_scope, raw.trust_scope))

    {:ok, capability} = Capability.new(raw)
    capability
  end

  defp task_request(task_input) do
    %TaskRequest{
      id: "tr-#{System.unique_integer([:positive])}",
      source: :cli,
      task_input: task_input,
      submitted_at_ms: System.system_time(:millisecond),
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

  describe "execute/2 — happy path" do
    test "invokes via guarded runner and returns :invoked with execution result" do
      runner = fn command, argv, _opts ->
        send(self(), {:ran, command, argv})
        {:ok, %{status: 0, stdout: "superpowers list output", stderr: ""}}
      end

      task = task_request("ooo superpowers list")

      assert {:ok, %{type: :user_level_plugin_invocation, status: :invoked} = result} =
               UserLevelPluginInvocation.execute(task, %{
                 capabilities: [superpowers_capability!()],
                 external_command_runner: runner
               })

      assert result.argv == ["superpowers", "list"]
      assert result.command == "ouroboros"
      assert result.execution.status == 0
      assert %PreflightResult{kind: :unique_match} = result.preflight
      assert_received {:ran, "ouroboros", ["superpowers", "list"]}
    end

    test "appends task args verbatim to argv" do
      runner = fn _cmd, _argv, _opts -> {:ok, %{status: 0, stdout: "", stderr: ""}} end

      task = task_request("ooo superpowers tdd --goal \"add retry\"")

      assert {:ok, %{status: :invoked, argv: argv}} =
               UserLevelPluginInvocation.execute(task, %{
                 capabilities: [superpowers_capability!()],
                 external_command_runner: runner
               })

      assert ["superpowers", "test-driven-development", "--goal" | _rest] = argv
    end
  end

  describe "execute/2 — blocked paths (no execution)" do
    test "trust missing blocks dispatch with structured reason" do
      runner = fn _cmd, _argv, _opts ->
        flunk("runner must not be called when trust is missing")
      end

      task = task_request("ooo superpowers list")

      assert {:ok, %{status: :blocked, blocked_reason: :trust_missing} = result} =
               UserLevelPluginInvocation.execute(task, %{
                 capabilities: [superpowers_capability!(trust_scope: [])],
                 external_command_runner: runner
               })

      assert result.preflight.trust_state == :missing
      assert result.preflight.remediation =~ "ouroboros plugin trust"
    end

    test "unknown command blocks with :unknown_plugin_or_command" do
      runner = fn _cmd, _argv, _opts -> flunk("must not run") end
      task = task_request("ooo superpowers nope")

      assert {:ok, %{status: :blocked, blocked_reason: :unknown_plugin_or_command}} =
               UserLevelPluginInvocation.execute(task, %{
                 capabilities: [superpowers_capability!()],
                 external_command_runner: runner
               })
    end

    test "destructive risk class blocks without explicit approval" do
      runner = fn _cmd, _argv, _opts -> flunk("must not run") end

      {:ok, destructive_cap} =
        Capability.new(%{
          plugin_id: "danger",
          source: :fixture,
          trust_scope: ["filesystem:write"],
          commands: [%{name: "wipe", risk_class: "destructive"}]
        })

      task = %{task_request("ooo danger wipe") | routing_decision: %{
                  kind: :user_level_plugin,
                  execution_route: :user_level_plugin,
                  runtime_source: :ouroboros,
                  transport: :auto,
                  requires_command_syntax?: false,
                  advanced_shortcut?: true,
                  reason: :user_level_plugin_resolved,
                  plugin_id: "danger"
                }}

      assert {:ok, %{status: :blocked, blocked_reason: :destructive_action_requires_approval}} =
               UserLevelPluginInvocation.execute(task, %{
                 capabilities: [destructive_cap],
                 external_command_runner: runner
               })
    end

    test "destructive risk class runs when explicit approval is granted" do
      runner = fn _cmd, _argv, _opts -> {:ok, %{status: 0, stdout: "ok", stderr: ""}} end

      {:ok, destructive_cap} =
        Capability.new(%{
          plugin_id: "danger",
          source: :fixture,
          trust_scope: ["filesystem:write"],
          commands: [%{name: "wipe", risk_class: "destructive"}]
        })

      task = task_request("ooo danger wipe")

      assert {:ok, %{status: :invoked}} =
               UserLevelPluginInvocation.execute(task, %{
                 capabilities: [destructive_cap],
                 external_command_runner: runner,
                 destructive_action_approved?: true
               })
    end
  end

  describe "execute/2 — runner contract" do
    test "missing runner errors :external_command_runner_not_configured" do
      task = task_request("ooo superpowers list")

      assert {:error, :external_command_runner_not_configured} =
               UserLevelPluginInvocation.execute(task, %{
                 capabilities: [superpowers_capability!()]
               })
    end

    test "invalid runner shape errors :invalid_external_command_runner" do
      task = task_request("ooo superpowers list")

      assert {:error, :invalid_external_command_runner} =
               UserLevelPluginInvocation.execute(task, %{
                 capabilities: [superpowers_capability!()],
                 external_command_runner: :not_a_function
               })
    end

    test "runner failure surfaces as blocked with structured reason" do
      runner = fn _cmd, _argv, _opts ->
        {:error, {:forbidden_external_command, :shell_wrapped_agent_command}}
      end

      task = task_request("ooo superpowers list")

      assert {:ok, %{status: :blocked, blocked_reason: {:external_command_failed, _}}} =
               UserLevelPluginInvocation.execute(task, %{
                 capabilities: [superpowers_capability!()],
                 external_command_runner: runner
               })
    end
  end

  describe "execute/2 — argv shell-injection guard handoff" do
    test "argv is a list with no shell concatenation, even with injection-shaped args" do
      runner = fn command, argv, _opts ->
        send(self(), {:argv, command, argv})
        {:ok, %{status: 0, stdout: "", stderr: ""}}
      end

      task = task_request(~s|ooo superpowers tdd --goal "; rm -rf /"|)

      assert {:ok, %{status: :invoked}} =
               UserLevelPluginInvocation.execute(task, %{
                 capabilities: [superpowers_capability!()],
                 external_command_runner: runner
               })

      assert_received {:argv, "ouroboros", argv}
      # Every arg is a separate list element. No element contains shell
      # metacharacters interpolated into another arg.
      assert is_list(argv)
      assert Enum.all?(argv, &is_binary/1)
    end
  end

  describe "execute/2 — context validation" do
    test "missing capabilities errors :capabilities_required_in_context" do
      task = task_request("ooo superpowers list")
      assert {:error, :capabilities_required_in_context} =
               UserLevelPluginInvocation.execute(task, %{external_command_runner: fn _, _, _ -> {:ok, %{}} end})
    end

    test "non-Capability items in :capabilities errors :invalid_capabilities_in_context" do
      task = task_request("ooo superpowers list")

      assert {:error, :invalid_capabilities_in_context} =
               UserLevelPluginInvocation.execute(task, %{
                 capabilities: [%{plugin_id: "x"}],
                 external_command_runner: fn _, _, _ -> {:ok, %{}} end
               })
    end
  end
end
