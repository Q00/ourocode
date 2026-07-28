defmodule Ourocode.CLITest.DashboardSpy do
  def init(context) do
    send(Application.fetch_env!(:ourocode, :cli_test_pid), {:dashboard_init, context})
    {:ok, %{context: context}}
  end
end

defmodule Ourocode.CLITest.TerminalBootstrapSpy do
  def bootstrap(context) do
    send(Application.fetch_env!(:ourocode, :cli_test_pid), {:terminal_bootstrap, context})
    {:ok, %{context: context, terminal_bootstrap?: true}}
  end
end

defmodule Ourocode.CLITest.InteractiveTerminalSpy do
  def bootstrap(context) do
    Ourocode.Dashboard.Application.init(context)
  end
end

defmodule Ourocode.CLITest.StartupHangRuntime do
  def bootstrap(_context) do
    receive do
    after
      :infinity -> :ok
    end
  end

  def shutdown(_runtime, _options), do: :ok
end

defmodule Ourocode.CLITest.ShutdownHangRuntime do
  def bootstrap(context) do
    journal_path = Map.fetch!(context, :journal_path)

    {:ok,
     %{
       status: :ready,
       healthy?: true,
       session_id: Map.get(context, :runtime_session_id, "shutdown-hang-runtime"),
       services: %{},
       service_statuses: %{},
       journal: %{
         path: journal_path,
         mode: :append_only_jsonl,
         replayable?: true,
         next_event_seq: 1,
         normalized_event_count: 0
       },
       event_pipeline: %{transports: [:stdio, :sse, :streamable_http]},
       pane_model: %{open: [:parent, :children, :queue, :status, :wonder_tool]},
       focus_state: %{route: :terminal_input_loop},
       plugins: %{status: :ready},
       commands: %{slash_commands_loaded?: true, natural_language_input?: true},
       queued_notifications: %{replayable?: true},
       hooks: %{output_summary?: true},
       wonder_tool: %{surface: :terminal}
     }}
  end

  def shutdown(_runtime, _options) do
    receive do
    after
      :infinity -> :ok
    end
  end
end

defmodule Ourocode.CLITest do
  use ExUnit.Case, async: false

  alias Ourocode.CLI.StartupArgs
  alias Ourocode.CLI.SmokeTest

  import ExUnit.CaptureIO
  import Ourocode.Test.PathAssertions, only: [assert_same_path: 2]

  test "startup resolves the current working directory by default" do
    assert Ourocode.CLI.resolve_project_dir() == {:ok, File.cwd!()}
  end

  test "startup honors the OUROCODE_PROJECT_DIR override" do
    System.put_env("OUROCODE_PROJECT_DIR", File.cwd!())

    try do
      assert Ourocode.CLI.resolve_project_dir(StartupArgs.default_project_dir()) ==
               {:ok, File.cwd!()}
    after
      System.delete_env("OUROCODE_PROJECT_DIR")
    end
  end

  test "startup argument parser separates launch args, config overrides, and task text" do
    project_dir = File.cwd!()

    assert {:ok, startup_args} =
             StartupArgs.parse([
               "--parallel-child-count",
               "5",
               "--project-dir",
               project_dir,
               "--repeat-count=2",
               "Investigate",
               "pane",
               "routing"
             ])

    assert startup_args.project_dir == Path.expand(project_dir)
    assert startup_args.smoke_test? == false
    assert startup_args.config_args == ["--parallel-child-count", "5", "--repeat-count=2"]
    assert startup_args.task_request.task_input == "Investigate pane routing"
  end

  test "startup argument parser accepts global options after task text" do
    project_dir = File.cwd!()

    assert {:ok, startup_args} =
             StartupArgs.parse([
               "Return",
               "ready",
               "--format",
               "json",
               "--project-dir",
               project_dir
             ])

    assert startup_args.project_dir == Path.expand(project_dir)
    assert startup_args.headless? == true
    assert startup_args.output_format == :json
    assert startup_args.task_request.task_input == "Return ready"
  end

  test "startup argument parser preserves post-separator flags as task text" do
    assert {:ok, startup_args} =
             StartupArgs.parse([
               "--project-dir",
               File.cwd!(),
               "--",
               "Return",
               "--format",
               "json"
             ])

    assert startup_args.output_format == :text
    assert startup_args.task_request.task_input == "Return --format json"
  end

  test "startup argument parser selects smoke test mode before task text" do
    assert {:ok, startup_args} =
             StartupArgs.parse([
               "--smoke-test",
               "--project-dir",
               File.cwd!(),
               "Check",
               "startup"
             ])

    assert startup_args.project_dir == File.cwd!()
    assert startup_args.smoke_test? == true
    assert startup_args.task_request.task_input == "Check startup"
  end

  test "launch prints help without bootstrapping the terminal UI" do
    output =
      capture_io(fn ->
        assert {:ok, %{mode: :help}} =
                 Ourocode.CLI.launch(["--help"], Ourocode.CLITest.TerminalBootstrapSpy)
      end)

    assert output =~ "Usage:"
    assert output =~ "--project-dir PATH"
    assert output =~ "--verify"
    assert output =~ "Verify startup, plugins, preflight, and guided work."
    assert output =~ "/preflight <command>"
    assert output =~ "Choose ooo pm, ooo interview, or ooo auto."
    assert output =~ "/agents, /sessions"
    assert output =~ "/mcp, /sandbox"
    assert output =~ "ooo"
    refute_receive {:terminal_bootstrap, _context}, 50
  end

  test "launch prints version without bootstrapping the terminal UI" do
    version = Mix.Project.config()[:version]

    output =
      capture_io(fn ->
        assert {:ok, %{mode: :version, version: ^version}} =
                 Ourocode.CLI.launch(["--version"], Ourocode.CLITest.TerminalBootstrapSpy)
      end)

    assert output == "ourocode #{version}\n"
    refute_receive {:terminal_bootstrap, _context}, 50
  end

  test "detect honors json output format without bootstrapping the terminal UI" do
    output =
      capture_io(fn ->
        assert {:ok, %{mode: :detect}} =
                 Ourocode.CLI.launch(
                   ["--detect", "--format", "json"],
                   Ourocode.CLITest.TerminalBootstrapSpy
                 )
      end)

    assert {:ok, evidence} = Ourocode.Json.decode(output)
    assert evidence["mode"] == "detect"
    assert is_list(evidence["models"])
    assert is_binary(evidence["default"])
    assert Enum.all?(evidence["models"], &Map.has_key?(&1, "status"))
    refute output =~ "ourocode detected backends:"
    refute_receive {:terminal_bootstrap, _context}, 50
  end

  test "verify flag selects non-interactive smoke verification mode" do
    assert {:ok, startup_args} =
             StartupArgs.parse([
               "--verify",
               "--project-dir",
               File.cwd!(),
               "Check",
               "startup"
             ])

    assert startup_args.smoke_test? == true
    assert startup_args.project_dir == File.cwd!()
    assert startup_args.task_request.task_input == "Check startup"
  end

  test "prompt and format flags select headless structured output mode" do
    assert {:ok, startup_args} =
             StartupArgs.parse([
               "--prompt",
               "Summarize repo startup",
               "--format",
               "json",
               "-d",
               File.cwd!()
             ])

    assert startup_args.headless? == true
    assert startup_args.output_format == :json
    assert startup_args.project_dir == File.cwd!()
    assert startup_args.task_request.task_input == "Summarize repo startup"
  end

  test "commands flag selects headless command discovery" do
    assert {:ok, startup_args} =
             StartupArgs.parse([
               "--commands",
               "--format",
               "json",
               "--project-dir",
               File.cwd!()
             ])

    assert startup_args.headless? == true
    assert startup_args.output_format == :json
    assert startup_args.project_dir == File.cwd!()
    assert startup_args.task_request.task_input == "/commands"
  end

  test "json-debug format selects headless structured debug output mode" do
    assert {:ok, startup_args} =
             StartupArgs.parse([
               "Summarize",
               "repo",
               "--format",
               "json-debug",
               "--project-dir",
               File.cwd!()
             ])

    assert startup_args.headless? == true
    assert startup_args.output_format == :json_debug
    assert startup_args.task_request.task_input == "Summarize repo"
  end

  test "startup invokes the dashboard initializer with resolved project context" do
    Application.put_env(:ourocode, :cli_test_pid, self())

    assert {:ok, %{context: context}} =
             Ourocode.CLI.main([], Ourocode.CLITest.DashboardSpy)

    assert_receive {:dashboard_init, ^context}
    assert context.project_dir == File.cwd!()
    assert is_binary(context.cwd)
    assert context.initial_task_request == nil
    assert context.plugin_config.plugins |> Enum.map(& &1.id) == ["ouroboros-plugin"]

    assert context.config == %{
             parallel_child_count: 3,
             repeat_count: 1,
             stream_mailbox_capacity: 1_000,
             stream_mailbox_overflow_path: :drop,
             stream_mailbox_backpressure_threshold: 800,
             stream_mailbox_backpressure_behavior: :notify,
             stream_mailbox_backpressure_delay_ms: 10,
             allowed_memory_growth_mb: 64,
             stale_cleanup_timeout_ms: 30_000,
             operation_timeout_ms: 120_000,
             stream_subscription_cleanup_timeout_ms: 10_000,
             pane_state_retention_ms: 300_000,
             cleanup_policy: %{
               allowed_memory_growth_mb: 64,
               stale_cleanup_timeout_ms: 30_000,
               stream_subscription_cleanup_timeout_ms: 10_000,
               pane_state_retention_ms: 300_000
             }
           }
  after
    Application.delete_env(:ourocode, :cli_test_pid)
  end

  test "startup invokes the terminal application bootstrap with parsed startup args" do
    Application.put_env(:ourocode, :cli_test_pid, self())

    assert {:ok, %{context: context, terminal_bootstrap?: true}} =
             Ourocode.CLI.main(
               ["--project-dir", File.cwd!(), "Review", "streaming", "status"],
               Ourocode.CLITest.TerminalBootstrapSpy
             )

    assert_receive {:terminal_bootstrap, ^context}
    assert context.project_dir == File.cwd!()
    assert context.initial_task_request.task_input == "Review streaming status"
  after
    Application.delete_env(:ourocode, :cli_test_pid)
  end

  test "startup loads project plugin config into terminal context" do
    Application.put_env(:ourocode, :cli_test_pid, self())
    project_dir = tmp_project_dir!("cli-plugin-config")
    File.mkdir_p!(Path.join(project_dir, ".ourocode"))

    File.write!(
      Path.join(project_dir, ".ourocode/config.json"),
      plugin_config_json()
    )

    assert {:ok, %{context: context, terminal_bootstrap?: true}} =
             Ourocode.CLI.main(
               ["--project-dir", project_dir],
               Ourocode.CLITest.TerminalBootstrapSpy
             )

    assert_receive {:terminal_bootstrap, ^context}
    assert_same_path(context.project_dir, project_dir)
    assert context.plugin_config.plugins |> Enum.map(& &1.id) == ["ouroboros-plugin"]
  after
    Application.delete_env(:ourocode, :cli_test_pid)
    cleanup_tmp_project_dir()
  end

  test "smoke test flag returns a non-interactive result without bootstrapping terminal UI" do
    Application.put_env(:ourocode, :cli_test_pid, self())

    assert {:ok, result} =
             Ourocode.CLI.main(
               ["--smoke-test", "--project-dir", File.cwd!(), "Smoke", "startup"],
               Ourocode.CLITest.TerminalBootstrapSpy
             )

    assert result.mode == :smoke_test
    assert result.status == :healthy
    assert result.interactive_ui_started? == false
    assert result.event_loop_started? == false
    assert result.runtime.status == :ready
    assert result.runtime.journal.normalized_event_count >= 1
    assert result.checks.runtime_initialized? == true
    assert result.checks.core_interaction_endpoint_free? == true
    assert result.checks.startup_state_recorded? == true
    assert result.checks.journal_replayable? == true
    assert result.context.project_dir == File.cwd!()
    assert result.context.initial_task_request.task_input == "Smoke startup"
    assert result.checks.project_dir_exists? == true
    assert result.checks.config_loaded? == true
    assert result.checks.task_request_accepted? == true

    refute_receive {:terminal_bootstrap, _context}, 50
  after
    Application.delete_env(:ourocode, :cli_test_pid)
  end

  test "smoke test mode initializes minimal runtime services and journals startup state" do
    project_dir = File.cwd!()
    journal_path = Path.join(System.tmp_dir!(), "ourocode-smoke-#{unique_id()}.jsonl")
    File.rm(journal_path)

    context =
      project_dir
      |> Ourocode.CLI.project_context(Ourocode.Config.defaults())
      |> Map.put(:initial_task_request, %Ourocode.TaskRequest{
        source: :cli,
        task_input: "Smoke startup state",
        routing_decision: %{
          kind: :mcp_flow,
          execution_route: :mcp_flow,
          requires_command_syntax?: false
        }
      })
      |> Map.put(:runtime_session_id, "smoke-runtime-test")
      |> Map.put(:journal_path, journal_path)

    assert {:ok, result} = SmokeTest.run(context, output: :silent)

    assert result.mode == :smoke_test
    assert result.status == :healthy
    assert result.interactive_ui_started? == false
    assert result.event_loop_started? == false

    assert result.runtime.status == :ready
    assert result.runtime.session_id == "smoke-runtime-test"
    assert result.runtime.service_statuses.runtime_registry == :ready
    assert result.runtime.service_statuses.event_pipeline == :ready
    assert result.runtime.service_statuses.command_registry == :ready
    assert result.runtime.service_statuses.wonder_tool == :ready
    assert result.shutdown.status == :shutdown_complete
    assert result.shutdown.orderly? == true
    assert result.shutdown.supervisor_alive_before? == true
    assert result.shutdown.supervisor_stopped? == true
    assert result.shutdown.services_stopped? == true
    assert result.shutdown.leaked_service_ids == []
    assert result.runtime.event_pipeline.transports == [:stdio, :sse, :streamable_http]
    assert result.runtime.pane_model.open == [:parent, :children, :queue, :status, :wonder_tool]
    assert result.runtime.focus_state.route == :terminal_input_loop
    assert result.runtime.commands.slash_commands_loaded? == true
    assert result.runtime.commands.natural_language_input? == true
    assert result.runtime.queued_notifications.replayable? == true
    assert result.runtime.hooks.output_summary? == true
    assert result.runtime.wonder_tool.surface == :terminal
    assert result.core_interaction_config_guard.status == :terminal_core_endpoint_free
    assert result.core_interaction_config_guard.core_interaction_requires_endpoint? == false

    assert result.checks == %{
             project_dir_exists?: true,
             config_loaded?: true,
             core_interaction_endpoint_free?: true,
             runtime_initialized?: true,
             runtime_shutdown?: true,
             startup_state_recorded?: true,
             journal_replayable?: true,
             task_request_accepted?: true
           }

    assert {:ok, [startup_event]} = Ourocode.Journal.read_ordered(journal_path)
    assert startup_event.event_seq == 1
    assert startup_event.type == :runtime_startup_succeeded
    assert startup_event.source == :cli
    assert startup_event.session_id == "smoke-runtime-test"

    assert startup_event.payload["initialized_services"] ==
             Enum.map(result.runtime.services, &Atom.to_string/1)

    assert startup_event.payload["project_dir"] == project_dir
    assert startup_event.payload["event_pipeline"]["no_loss_policy"] == "journal_before_render"

    assert startup_event.payload["core_interaction_config_guard"][
             "core_interaction_requires_endpoint?"
           ] == false
  end

  test "smoke test mode performs orderly shutdown and releases runtime resources" do
    project_dir = File.cwd!()
    journal_path = Path.join(System.tmp_dir!(), "ourocode-smoke-shutdown-#{unique_id()}.jsonl")
    File.rm(journal_path)

    context =
      project_dir
      |> Ourocode.CLI.project_context(Ourocode.Config.defaults())
      |> Map.put(:runtime_session_id, "smoke-shutdown-test")
      |> Map.put(:journal_path, journal_path)

    assert {:ok, result} = SmokeTest.run(context, output: :silent)

    assert result.status == :healthy

    assert result.shutdown == %{
             status: :shutdown_complete,
             orderly?: true,
             supervisor_alive_before?: true,
             supervisor_stopped?: true,
             service_count: 14,
             services_stopped?: true,
             released_service_ids: [
               :child_supervisor,
               :command_registry,
               :event_pipeline,
               :focus_state,
               :hook_lifecycle,
               :pane_model,
               :plugin_config_watcher,
               :plugin_registry,
               :queued_notifications,
               :runtime_registry,
               :session_supervisor,
               :transport_supervisor,
               :user_level_plugin_registry,
               :wonder_tool
             ],
             leaked_service_ids: [],
             checked_at_ms: result.shutdown.checked_at_ms
           }

    assert result.checks.runtime_shutdown? == true
    assert {:ok, [_startup_event]} = Ourocode.Journal.read_ordered(journal_path)
  end

  test "smoke test mode times out deterministically when runtime startup hangs" do
    project_dir = File.cwd!()

    context =
      project_dir
      |> Ourocode.CLI.project_context(Ourocode.Config.defaults())
      |> Map.put(:runtime_session_id, "smoke-startup-timeout-test")
      |> Map.put(
        :journal_path,
        Path.join(System.tmp_dir!(), "ourocode-smoke-startup-timeout-#{unique_id()}.jsonl")
      )

    started_at = System.monotonic_time(:millisecond)

    assert {:error, result} =
             SmokeTest.run(context,
               output: :silent,
               runtime_application: Ourocode.CLITest.StartupHangRuntime,
               timeout_ms: 25
             )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms < 1_000
    assert result.status == :unhealthy
    assert result.healthy? == false
    assert result.mode == :smoke_test
    assert result.reason == :smoke_test_timeout
    assert result.phase == :startup
    assert result.timeout_ms == 25
    assert result.deterministic_failure? == true
    assert result.interactive_ui_started? == false
    assert result.event_loop_started? == false
    assert result.checks.runtime_initialized? == false
    assert result.checks.runtime_shutdown? == false
    assert result.checks.startup_state_recorded? == false
  end

  test "smoke test mode times out deterministically when runtime shutdown hangs" do
    project_dir = File.cwd!()

    journal_path =
      Path.join(System.tmp_dir!(), "ourocode-smoke-shutdown-timeout-#{unique_id()}.jsonl")

    File.rm(journal_path)

    context =
      project_dir
      |> Ourocode.CLI.project_context(Ourocode.Config.defaults())
      |> Map.put(:runtime_session_id, "smoke-shutdown-timeout-test")
      |> Map.put(:journal_path, journal_path)

    started_at = System.monotonic_time(:millisecond)

    assert {:error, result} =
             SmokeTest.run(context,
               output: :silent,
               runtime_application: Ourocode.CLITest.ShutdownHangRuntime,
               timeout_ms: 25
             )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms < 1_000
    assert result.status == :unhealthy
    assert result.healthy? == false
    assert result.reason == :smoke_test_timeout
    assert result.phase == :shutdown
    assert result.timeout_ms == 25
    assert result.deterministic_failure? == true
    assert result.runtime.status == :ready
    assert result.runtime.session_id == "smoke-shutdown-timeout-test"
    assert result.checks.runtime_initialized? == true
    assert result.checks.runtime_shutdown? == false
    assert result.checks.startup_state_recorded? == true
    assert result.checks.journal_replayable? == true

    assert {:ok, [startup_event]} = Ourocode.Journal.read_ordered(journal_path)
    assert startup_event.type == :runtime_startup_succeeded
    assert startup_event.session_id == "smoke-shutdown-timeout-test"
  end

  test "smoke test can be selected from startup config without bootstrapping terminal UI" do
    original_smoke_test = Application.get_env(:ourocode, :smoke_test)

    on_exit(fn ->
      restore_env(:smoke_test, original_smoke_test)
    end)

    Application.put_env(:ourocode, :cli_test_pid, self())
    Application.put_env(:ourocode, :smoke_test, true)

    assert {:ok, result} =
             Ourocode.CLI.main(
               ["--project-dir", File.cwd!()],
               Ourocode.CLITest.TerminalBootstrapSpy
             )

    assert result.mode == :smoke_test
    assert result.interactive_ui_started? == false
    assert result.event_loop_started? == false
    refute_receive {:terminal_bootstrap, _context}, 50
  after
    Application.delete_env(:ourocode, :cli_test_pid)
  end

  test "startup accepts a natural-language task submission without command syntax" do
    Application.put_env(:ourocode, :cli_test_pid, self())

    assert {:ok, %{context: context}} =
             Ourocode.CLI.main(
               ["Investigate", "MCP", "stream", "loss"],
               Ourocode.CLITest.DashboardSpy
             )

    assert_receive {:dashboard_init, ^context}

    assert %Ourocode.TaskRequest{
             source: :cli,
             task_input: "Investigate MCP stream loss",
             routing_decision: %{
               kind: :mcp_flow,
               execution_route: :mcp_flow,
               requires_command_syntax?: false
             }
           } = context.initial_task_request
  after
    Application.delete_env(:ourocode, :cli_test_pid)
  end

  test "startup applies configured parallel child and repeat count overrides" do
    original_parallel_child_count = Application.get_env(:ourocode, :parallel_child_count)
    original_repeat_count = Application.get_env(:ourocode, :repeat_count)

    on_exit(fn ->
      restore_env(:parallel_child_count, original_parallel_child_count)
      restore_env(:repeat_count, original_repeat_count)
    end)

    Application.put_env(:ourocode, :cli_test_pid, self())
    Application.put_env(:ourocode, :parallel_child_count, 8)
    Application.put_env(:ourocode, :repeat_count, 4)

    assert {:ok, %{context: context}} =
             Ourocode.CLI.main([], Ourocode.CLITest.DashboardSpy)

    assert_receive {:dashboard_init, ^context}

    assert context.config == %{
             parallel_child_count: 8,
             repeat_count: 4,
             stream_mailbox_capacity: 1_000,
             stream_mailbox_overflow_path: :drop,
             stream_mailbox_backpressure_threshold: 800,
             stream_mailbox_backpressure_behavior: :notify,
             stream_mailbox_backpressure_delay_ms: 10,
             allowed_memory_growth_mb: 64,
             stale_cleanup_timeout_ms: 30_000,
             operation_timeout_ms: 120_000,
             stream_subscription_cleanup_timeout_ms: 10_000,
             pane_state_retention_ms: 300_000,
             cleanup_policy: %{
               allowed_memory_growth_mb: 64,
               stale_cleanup_timeout_ms: 30_000,
               stream_subscription_cleanup_timeout_ms: 10_000,
               pane_state_retention_ms: 300_000
             }
           }
  after
    Application.delete_env(:ourocode, :cli_test_pid)
  end

  test "startup applies CLI pane retention and cleanup policy overrides" do
    Application.put_env(:ourocode, :cli_test_pid, self())

    args = [
      "--cleanup-policy.allowed-memory-growth-mb=192",
      "--cleanup-policy.stale-cleanup-timeout-ms=55000",
      "--cleanup-policy.stream-subscription-cleanup-timeout-ms=15000",
      "--cleanup-policy.pane-state-retention-ms=700000"
    ]

    assert {:ok, %{context: context}} =
             Ourocode.CLI.main(args, Ourocode.CLITest.DashboardSpy)

    assert_receive {:dashboard_init, ^context}

    assert context.config == %{
             parallel_child_count: 3,
             repeat_count: 1,
             stream_mailbox_capacity: 1_000,
             stream_mailbox_overflow_path: :drop,
             stream_mailbox_backpressure_threshold: 800,
             stream_mailbox_backpressure_behavior: :notify,
             stream_mailbox_backpressure_delay_ms: 10,
             allowed_memory_growth_mb: 192,
             stale_cleanup_timeout_ms: 55_000,
             operation_timeout_ms: 120_000,
             stream_subscription_cleanup_timeout_ms: 15_000,
             pane_state_retention_ms: 700_000,
             cleanup_policy: %{
               allowed_memory_growth_mb: 192,
               stale_cleanup_timeout_ms: 55_000,
               stream_subscription_cleanup_timeout_ms: 15_000,
               pane_state_retention_ms: 700_000
             }
           }
  after
    Application.delete_env(:ourocode, :cli_test_pid)
  end

  test "launch renders once and keeps the terminal event loop alive until explicit exit" do
    lines = start_lines(["Investigate streaming panes\n", "/exit\n"])

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 Ourocode.CLI.launch(
                   ["--project-dir", File.cwd!()],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: next_line(lines)
                 )

        assert result.status == :healthy
        assert result.event_loop.status == :exit_signal_received
        assert result.event_loop.iterations == 2

        assert Enum.map(result.event_loop.submitted_tasks, & &1.task_input) == [
                 "Investigate streaming panes"
               ]
      end)

    assert output =~ "ourocode agent"
    assert output =~ "Start here:"
    assert output =~ "task: queued"
    assert output =~ "exiting ourocode"
  end

  test "launch consumes piped stdin to EOF and exits cleanly without interactive input" do
    lines =
      start_lines([
        "Inspect stdin prompt flow\n",
        "Steer child pane from stdin\n"
      ])

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 Ourocode.CLI.launch(
                   ["--project-dir", File.cwd!()],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: next_line(lines)
                 )

        assert result.status == :healthy
        assert result.event_loop.status == :input_eof
        assert result.event_loop.exit_signal == nil
        assert result.event_loop.iterations == 2

        assert Enum.map(result.event_loop.submitted_tasks, & &1.task_input) == [
                 "Inspect stdin prompt flow",
                 "Steer child pane from stdin"
               ]
      end)

    assert output =~ "ourocode agent"
    assert output =~ "task: queued"
    refute output =~ "exiting ourocode"
  end

  test "launch smoke test prints smoke summary and does not enter prompt loop" do
    output =
      capture_io(fn ->
        assert {:ok, result} =
                 Ourocode.CLI.launch(
                   ["--smoke-test", "--project-dir", File.cwd!()],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: fn _prompt -> flunk("smoke launch must not read terminal input") end
                 )

        assert result.mode == :smoke_test
        refute Map.has_key?(result, :event_loop)
      end)

    assert output =~ "ourocode smoke test: ok"
    assert output =~ "mode: smoke_test"
    assert output =~ "interactive_ui_started?: false"
    refute output =~ "ourocode terminal"
    refute output =~ "ourocode> "
  end

  test "launch verify mode emits product verification evidence and does not enter prompt loop" do
    output =
      capture_io(fn ->
        assert {:ok, result} =
                 Ourocode.CLI.launch(
                   ["--verify", "--format", "json", "--project-dir", File.cwd!()],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: fn _prompt ->
                     flunk("verify launch must not read terminal input")
                   end
                 )

        assert result.mode == :verification
        refute Map.has_key?(result, :event_loop)
      end)

    assert {:ok, evidence} = Ourocode.Json.decode(output)
    assert evidence["mode"] == "verification"
    assert evidence["ok"] == true
    assert evidence["status"] == "passed"
    assert evidence["action"]["kind"] == "verify"
    assert evidence["verification"]["status"] == "passed"

    check_names = Enum.map(evidence["verification"]["checks"], & &1["name"])

    assert check_names == [
             "startup ready",
             "tools connected",
             "agent workspace ready",
             "guided interview ready",
             "terminal UI ready"
           ]

    refute Map.has_key?(evidence["verification"], "artifacts")

    debug_output =
      capture_io(fn ->
        assert {:ok, debug_result} =
                 Ourocode.CLI.launch(
                   ["--verify", "--format", "json-debug", "--project-dir", File.cwd!()],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: fn _prompt ->
                     flunk("verify launch must not read terminal input")
                   end
                 )

        assert debug_result.mode == :verification
      end)

    assert {:ok, debug_evidence} = Ourocode.Json.decode(debug_output)
    artifacts = debug_evidence["verification"]["artifacts"]
    assert artifacts["plugin_status_text"] =~ "Plugins"
    assert artifacts["plugin_status_text"] =~ "ready; 1 installed plugin"
    assert artifacts["plugin_status_text"] =~ ">> Guided workflows"

    assert artifacts["plugin_status_text"] =~ "Open /mcp | /verify"
    assert artifacts["plugin_status_text"] =~ "type to compose"
    assert artifacts["agents_workspace_text"] =~ "Guided work"
    assert artifacts["agents_workspace_text"] =~ "PM interview"
    assert artifacts["agents_workspace_text"] =~ "type to compose"
    refute artifacts["agents_workspace_text"] =~ "shortcuts active"
    assert artifacts["initial_frame_text"] =~ "Start here:"
    assert artifacts["initial_frame_text"] =~ "ooo pm <goal>"
    assert artifacts["initial_frame_text"] =~ "ooo interview <goal>"
    assert artifacts["initial_frame_text"] =~ "ooo auto <goal>"
    refute artifacts["initial_frame_text"] =~ "Primary path:"
    assert artifacts["active_agents_workspace_text"] =~ "running, 1 active; 1 lane"
    assert artifacts["active_agents_workspace_text"] =~ "PM interview - waiting · live"
    assert artifacts["active_agents_workspace_text"] =~ "generating answer choices"
    assert artifacts["active_agents_workspace_text"] =~ "answer accepted"
    refute artifacts["active_agents_workspace_text"] =~ "activity · round 2"
    assert artifacts["lifecycle_agents_workspace_text"] =~ "running, 1 active; 3 lanes"
    assert artifacts["lifecycle_agents_workspace_text"] =~ "PM interview - queued"

    assert artifacts["lifecycle_agents_workspace_text"] =~
             "Attention needed - failed · needs attention"

    assert artifacts["lifecycle_agents_workspace_text"] =~ "Stopped work - cancelled · stopped"
    refute artifacts["lifecycle_agents_workspace_text"] =~ "activity · work queued"

    assert artifacts["submitted_workflow_agents_workspace_text"] =~
             "running, 1 active; 1 lane"

    assert artifacts["submitted_workflow_agents_workspace_text"] =~ "verify lifecycle work"

    refute artifacts["submitted_workflow_agents_workspace_text"] =~
             "activity · work preparing question"

    assert artifacts["submitted_workflow_lifecycle_text"] =~ "frame submitted queued:"

    assert artifacts["submitted_workflow_lifecycle_text"] =~
             "ooo pm verify lifecycle stream focus cancel error"

    assert artifacts["submitted_workflow_lifecycle_text"] =~ "frame streaming focused:"

    assert artifacts["submitted_workflow_lifecycle_text"] =~
             "3 events, updates connected"

    refute artifacts["submitted_workflow_lifecycle_text"] =~ "focused in workspace"
    assert artifacts["submitted_workflow_lifecycle_text"] =~ "frame paused:"
    assert artifacts["submitted_workflow_lifecycle_text"] =~ "paused"
    assert artifacts["submitted_workflow_lifecycle_text"] =~ "frame recovery resumed:"
    assert artifacts["submitted_workflow_lifecycle_text"] =~ "recovered and streaming again"
    assert artifacts["submitted_workflow_lifecycle_text"] =~ "frame cancel acknowledged:"
    assert artifacts["submitted_workflow_lifecycle_text"] =~ "cancelled · stopped"
    assert artifacts["submitted_workflow_lifecycle_text"] =~ "frame error captured:"
    assert artifacts["submitted_workflow_lifecycle_text"] =~ "frame completed:"
    assert artifacts["submitted_workflow_lifecycle_text"] =~ "completed · done"
    assert artifacts["submitted_workflow_lifecycle_text"] =~ "runtime event proof:"
    assert artifacts["submitted_workflow_lifecycle_text"] =~ "pause/resume:"

    assert artifacts["workflow_fast_answer_recovery_text"] =~ "fast answer: buffered"

    assert artifacts["workflow_fast_answer_recovery_text"] =~
             "recovery: interview session did not open"

    assert artifacts["workflow_fast_answer_recovery_text"] =~ "pending after failure: nil"
    assert artifacts["live_turn_feedback_text"] =~ "live: PM interview is opening"
    assert artifacts["live_turn_feedback_text"] =~ "activity:"
    assert artifacts["live_turn_feedback_text"] =~ "Queue a follow-up; Esc interrupts"
    assert artifacts["live_turn_feedback_text"] =~ "pulse: watching for first question"
    assert artifacts["submitted_workflow_lifecycle_text"] =~ "failed · needs attention"
    refute artifacts["submitted_workflow_lifecycle_text"] =~ "projects stream"
    assert artifacts["auto_workflow_progression_text"] =~ "frame auto interview:"
    assert artifacts["auto_workflow_progression_text"] =~ "interview"
    assert artifacts["auto_workflow_progression_text"] =~ "frame auto seed plan:"
    assert artifacts["auto_workflow_progression_text"] =~ "seed plan"
    assert artifacts["auto_workflow_progression_text"] =~ "frame auto approval:"

    assert artifacts["auto_workflow_progression_text"] =~
             "Approval required before file changes"

    assert artifacts["auto_workflow_progression_text"] =~ "preview auto execute:"
    assert artifacts["auto_workflow_progression_text"] =~ "execute"
    assert artifacts["auto_workflow_progression_text"] =~ "no files changed"
    assert artifacts["auto_workflow_progression_text"] =~ "preview auto verify:"
    assert artifacts["auto_workflow_progression_text"] =~ "verify preview"
    assert artifacts["auto_workflow_progression_text"] =~ "no verification run claimed"
    refute artifacts["auto_workflow_progression_text"] =~ "completed · done"
    assert artifacts["auto_workflow_progression_text"] =~ "not runtime completion proof"
    assert artifacts["auto_live_approval_gate_text"] =~ "real auto approval gate proof:"

    if not String.contains?(
         artifacts["auto_live_approval_gate_text"],
         "unavailable inside ExUnit"
       ) and
         not String.contains?(
           artifacts["auto_live_approval_gate_text"],
           "pseudo-tty proof is unavailable or already running"
         ) do
      assert artifacts["auto_live_approval_gate_text"] =~
               "stages: auto_submit -> auto_approval_plan -> auto_agents -> auto_approved_sandbox"

      assert artifacts["auto_live_approval_gate_text"] =~
               "sandbox execution captured: true"

      assert artifacts["auto_live_approval_gate_text"] =~
               "boundary: live proof proves sandbox execution only"
    end

    assert artifacts["preflight_text"] =~ "action: start guided work"
    assert artifacts["workflow_preview_result"] =~ "PM interview preview"
    assert artifacts["workflow_preview_result"] =~ "round 1:"
    assert artifacts["workflow_preview_result"] =~ "round 2:"
    refute artifacts["workflow_preview_result"] =~ "Open the TUI"
    assert artifacts["workflow_first_question_text"] =~ ">> [1]"
    assert artifacts["workflow_first_question_text"] =~ "developer/builder onboarding workflow"
    assert artifacts["workflow_answer_roundtrip_text"] =~ "round 1:"
    assert artifacts["workflow_answer_roundtrip_text"] =~ "round 2:"
    assert artifacts["workflow_answer_roundtrip_text"] =~ "stop: user_done"
    assert artifacts["tty_scenario_frames_text"] =~ "frame empty:"
    assert artifacts["tty_scenario_frames_text"] =~ "ooo structured work"
    assert artifacts["tty_scenario_frames_text"] =~ "INTERVIEW"
    assert artifacts["tty_scenario_frames_text"] =~ "frame answer transition:"
    assert artifacts["tty_scenario_frames_text"] =~ "Round accepted"
    assert artifacts["tty_scenario_frames_text"] =~ "Next opening interview session"
    assert artifacts["tty_scenario_frames_text"] =~ "frame answer sent transition:"
    assert artifacts["tty_scenario_frames_text"] =~ "Next answer sent; generating choices"
    refute artifacts["tty_scenario_frames_text"] =~ "SYNC opening interview session"
    refute artifacts["tty_scenario_frames_text"] =~ "SYNC answer sent; generating choices"
    assert artifacts["tty_scenario_frames_text"] =~ "building next answer choices"
    assert artifacts["tty_scenario_frames_text"] =~ "No input needed"
    assert artifacts["tty_scenario_frames_text"] =~ "Delegated work"
    assert artifacts["tty_scenario_frames_text"] =~ "Current task"
    assert artifacts["tty_scenario_frames_text"] =~ "resized active work:"
    assert artifacts["tty_scenario_frames_text"] =~ "workspace focus:"
    assert artifacts["tty_scenario_frames_text"] =~ "Plugins"
    assert artifacts["tty_scenario_frames_text"] =~ "workspace focus"
    refute artifacts["tty_scenario_frames_text"] =~ "MCP parent live"
    refute artifacts["tty_scenario_frames_text"] =~ "child stream live"
    refute artifacts["tty_scenario_frames_text"] =~ "activity log live"
    refute artifacts["tty_scenario_frames_text"] =~ "parent-verify"
    refute artifacts["tty_scenario_frames_text"] =~ "child-verify"
    refute artifacts["tty_scenario_frames_text"] =~ "offline"
    refute artifacts["tty_scenario_frames_text"] =~ ~r/\b(ASK|YOU|You)\b/
    assert artifacts["tty_interaction_contract_text"] =~ "ooo submit route: local submit"
    assert artifacts["tty_interaction_contract_text"] =~ "answer path: selected option 1"

    assert artifacts["tty_interaction_contract_text"] =~
             "command-like input: held for explicit command handling"

    assert artifacts["tty_interaction_contract_text"] =~ "pause path: Esc paused interview"

    assert artifacts["tty_interaction_contract_text"] =~
             "cancel path: checkpoint and interview stopped"

    assert artifacts["tty_interaction_contract_text"] =~ "exact /cancel uses clean cancel surface"
    assert artifacts["tty_interaction_contract_text"] =~ "cancel surface: stale activity cleared"
    assert artifacts["tty_live_smoke_text"] =~ "live tty smoke:"
    assert artifacts["tty_live_smoke_text"] =~ "picker_ms:"
    assert artifacts["tty_live_smoke_text"] =~ "command_held_ms:"
    assert artifacts["tty_live_smoke_text"] =~ "paused_ms:"
    assert artifacts["tty_live_smoke_text"] =~ "cancelled_ms:"
    assert artifacts["tty_live_smoke_text"] =~ "auto_workflow_ms:"
    assert artifacts["tty_live_smoke_text"] =~ "clean_cancel:"

    if not String.contains?(artifacts["tty_live_smoke_text"], "skipped inside ExUnit") do
      assert artifacts["tty_live_smoke_text"] =~ "pm_live_pulse: true"
      assert artifacts["tty_live_smoke_text"] =~ "auto_workflow: true"
      assert artifacts["tty_live_smoke_text"] =~ "auto_approval_plan: true"
      assert artifacts["tty_live_smoke_text"] =~ "auto_approved_sandbox: true"
      assert artifacts["tty_live_smoke_text"] =~ "auto_submit"
      assert artifacts["tty_live_smoke_text"] =~ "auto_approval_plan"
      assert artifacts["tty_live_smoke_text"] =~ "auto_approved_sandbox"
    end

    assert artifacts["theme_visuals_text"] =~ "theme visual surfaces:"
    assert artifacts["theme_visuals_text"] =~ "light frame: 250,250,249"
    assert artifacts["theme_visuals_text"] =~ "light frame: 250,250,249 242,242,240"
    assert artifacts["theme_visuals_text"] =~ "dark frame: 10,10,11"
    assert artifacts["theme_visuals_text"] =~ "dark frame: 10,10,11 17,17,17"
    assert artifacts["visual_captures_text"] =~ "visual capture set:"
    assert artifacts["visual_captures_text"] =~ "temporary visual proof: true"
    assert artifacts["visual_captures_text"] =~ "visual artifact files:"
    assert artifacts["visual_captures_text"] =~ "readme_hero:"
    assert artifacts["visual_captures_text"] =~ "pm_picker:"
    assert artifacts["visual_captures_text"] =~ "ourocode-visual-proof-"
    assert artifacts["visual_captures_text"] =~ "capture first start:"
    assert artifacts["visual_captures_text"] =~ "ooo pm <goal>"
    assert artifacts["visual_captures_text"] =~ "capture PM picker:"
    assert artifacts["visual_captures_text"] =~ ">> [1] Define the target user"
    assert artifacts["visual_captures_text"] =~ "capture agents:"
    assert artifacts["visual_captures_text"] =~ "guided work"
    assert artifacts["visual_captures_text"] =~ "capture cancel:"
    assert artifacts["visual_captures_text"] =~ "Interview stopped"
    assert artifacts["visual_captures_text"] =~ "Interview Stopped · interview"
    assert artifacts["visual_captures_text"] =~ "Start ooo pm <goal>"
    refute artifacts["visual_captures_text"] =~ "• Interview cancelled."
    refute artifacts["visual_captures_text"] =~ ">> Interview cancelled."
    assert artifacts["visual_captures_text"] =~ "capture verify:"
    assert artifacts["visual_captures_text"] =~ "checks: 22/22 passed"
    assert artifacts["visual_captures_text"] =~ "real terminal replay"
    assert artifacts["visual_captures_text"] =~ "capture theme:"
    assert artifacts["pixel_captures_text"] =~ "pixel capture proof:"
    assert artifacts["pixel_captures_text"] =~ "temporary PNG proof: true"
    assert artifacts["pixel_captures_text"] =~ "first_start:"
    assert artifacts["pixel_captures_text"] =~ "pm_picker:"
    assert artifacts["pixel_captures_text"] =~ "live_pulse:"
    assert artifacts["pixel_captures_text"] =~ "theme_light:"
    assert artifacts["pixel_captures_text"] =~ "theme_dark:"
    assert artifacts["pixel_captures_text"] =~ "human replay GIF:"

    if not String.contains?(artifacts["tty_live_smoke_text"], "skipped inside ExUnit") do
      assert artifacts["pixel_captures_text"] =~ "human replay from real PTY stages"
    end

    assert artifacts["pixel_captures_text"] =~ "non_bg="
    assert artifacts["pixel_captures_text"] =~ "accent="

    forbidden = [
      "region=",
      "visible=",
      "plugin_path",
      "plugin_id",
      "source:",
      "trust:",
      "risk:",
      "ouroboros-plugin",
      "TTY smoke",
      "preview evidence",
      "Verifier",
      "Question helper"
    ]

    Enum.each(Map.values(artifacts), fn artifact ->
      Enum.each(forbidden, fn token -> refute artifact =~ token end)
    end)

    assert Enum.all?(evidence["events"], &(&1["type"] == "check"))
  end

  test "launch prompt mode emits JSON evidence and does not enter prompt loop" do
    original_headless_model = Process.get(:ourocode_headless_model)
    Process.put(:ourocode_headless_model, fake_headless_model("startup contract ok"))

    on_exit(fn ->
      restore_process_value(:ourocode_headless_model, original_headless_model)
    end)

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 Ourocode.CLI.launch(
                   [
                     "--prompt",
                     "Check startup contract",
                     "--format",
                     "json",
                     "--project-dir",
                     File.cwd!()
                   ],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: fn _prompt ->
                     flunk("headless prompt must not read terminal input")
                   end
                 )

        assert result.mode == :headless_prompt
        refute Map.has_key?(result, :event_loop)
      end)

    assert {:ok, evidence} = Ourocode.Json.decode(output)
    assert evidence["mode"] == "headless"
    assert evidence["prompt"] == "Check startup contract"
    assert evidence["output_format"] == "json"
    assert evidence["status"] == "ready"
    assert evidence["action"]["kind"] == "model"
    assert evidence["prompt_status"]["accepted"] == true
    assert evidence["prompt_status"]["executed"] == true
    assert evidence["prompt_status"]["result_available"] == true
    assert evidence["model"]["id"] == "fake"
    assert evidence["result"] == "startup contract ok"
    assert evidence["result_available"] == true

    assert Enum.map(evidence["events"], & &1["type"]) == [
             "accepted",
             "ready",
             "message",
             "completed"
           ]

    refute Map.has_key?(evidence, "routing_decision")
    refute Map.has_key?(evidence, "runtime_session_id")
    refute Map.has_key?(evidence, "services")
    refute Map.has_key?(evidence, "checks")
    refute Map.has_key?(evidence, "journal_events")
    refute Map.has_key?(evidence, "journal_replayable")

    refute output =~ "ourocode terminal"
    refute output =~ "ourocode> "
  end

  test "launch prompt mode can emit JSON debug evidence with internal diagnostics" do
    original_headless_model = Process.get(:ourocode_headless_model)
    Process.put(:ourocode_headless_model, fake_headless_model("debug contract ok"))

    on_exit(fn ->
      restore_process_value(:ourocode_headless_model, original_headless_model)
    end)

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 Ourocode.CLI.launch(
                   [
                     "--prompt",
                     "Check debug contract",
                     "--format",
                     "json-debug",
                     "--project-dir",
                     File.cwd!()
                   ],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: fn _prompt ->
                     flunk("headless prompt must not read terminal input")
                   end
                 )

        assert result.mode == :headless_prompt
      end)

    assert {:ok, evidence} = Ourocode.Json.decode(output)
    assert evidence["mode"] == "headless_prompt"
    assert evidence["output_format"] == "json_debug"
    assert evidence["routing_decision"]["kind"] in ["runtime", "mcp_flow", "ouroboros_workflow"]
    assert is_binary(evidence["runtime_session_id"])
    assert is_list(evidence["services"])
    assert is_integer(evidence["journal_events"])

    assert Enum.map(evidence["events"], & &1["type"]) ==
             [
               "prompt_accepted",
               "runtime_verified",
               "model_selected",
               "step_start",
               "text_delta",
               "step_finish",
               "final_result"
             ]
  end

  test "launch prompt mode reports unavailable model without entering prompt loop" do
    original_headless_model = Process.get(:ourocode_headless_model)

    Process.put(:ourocode_headless_model, %Ourocode.Model{
      id: :missing,
      label: "missing model",
      kind: :cli,
      status: :unavailable,
      run: fn _prompt, _opts, _on_chunk -> flunk("unavailable model must not run") end
    })

    on_exit(fn ->
      restore_process_value(:ourocode_headless_model, original_headless_model)
    end)

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 Ourocode.CLI.launch(
                   [
                     "--prompt",
                     "Check missing model path",
                     "--format",
                     "json",
                     "--project-dir",
                     File.cwd!()
                   ],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: fn _prompt ->
                     flunk("headless prompt must not read terminal input")
                   end
                 )

        assert result.mode == :headless_prompt
        refute Map.has_key?(result, :event_loop)
      end)

    assert {:ok, evidence} = Ourocode.Json.decode(output)
    assert evidence["prompt_status"]["accepted"] == true
    assert evidence["prompt_status"]["executed"] == false
    assert evidence["prompt_status"]["result_available"] == false
    assert evidence["prompt_status"]["error"]["reason"] == "model_unavailable"
    assert evidence["result_available"] == false

    assert Enum.map(evidence["events"], & &1["type"]) == ["accepted", "ready", "skipped"]
  end

  test "headless ouroboros workflow prompt returns workflow evidence instead of generic model chat" do
    output =
      capture_io(fn ->
        assert {:ok, result} =
                 Ourocode.CLI.launch(
                   [
                     "ooo",
                     "pm",
                     "build",
                     "onboarding",
                     "--format",
                     "json",
                     "--project-dir",
                     File.cwd!()
                   ],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: fn _prompt ->
                     flunk("headless workflow prompt must not read terminal input")
                   end
                 )

        assert result.mode == :headless_prompt
      end)

    assert {:ok, evidence} = Ourocode.Json.decode(output)
    assert evidence["action"]["kind"] == "guided_work"
    assert evidence["prompt_status"]["executed"] == true
    assert evidence["prompt_status"]["message"] =~ "first-question"
    assert evidence["result"] =~ "PM interview preview"
    assert evidence["result"] =~ "round 1:"
    assert evidence["result"] =~ ">> [1]"
    assert evidence["result"] =~ "round 2:"
    assert evidence["result"] =~ "First PM brief is actionable"
    assert evidence["result"] =~ "Interview can continue"
    assert evidence["result"] =~ "Seed inputs are ready"

    refute evidence["result"] =~
             "round 2:\nWhat completion signal proves the interview produced the right onboarding result?\n\npreview scope"

    refute evidence["result"] =~ "Open the TUI"

    assert Enum.map(evidence["events"], & &1["type"]) == [
             "accepted",
             "ready",
             "guided_work",
             "question",
             "answer",
             "question",
             "completed"
           ]

    first_question_event =
      Enum.find(evidence["events"], &(&1["type"] == "question" and &1["round"] == 1))

    assert first_question_event["question"] =~ "build onboarding"

    assert Enum.map(first_question_event["options"], & &1["label"]) == [
             "Define the target user",
             "Define the activation outcome",
             "Audit the existing flow"
           ]

    second_question_event =
      Enum.find(evidence["events"], &(&1["type"] == "question" and &1["round"] == 2))

    assert Enum.map(second_question_event["options"], & &1["label"]) == [
             "First PM brief is actionable",
             "Interview can continue",
             "Seed inputs are ready"
           ]

    refute evidence["result"] =~ "I can"
  end

  test "headless pm workflow normalizes model-spaced CJK task text" do
    spaced_goal =
      [
        hangul([0xC6B4, 0xC601]),
        hangul([0xC911]),
        hangul([0xC2E4, 0xD328]),
        hangul([0xCF00, 0xC774, 0xC2A4]),
        hangul([0xB300, 0xC751]),
        hangul([0xC911])
      ]
      |> Enum.map(&(&1 |> String.graphemes() |> Enum.join(" ")))
      |> Enum.join("  ")

    expected_goal =
      [
        hangul([0xC6B4, 0xC601]),
        hangul([0xC911]),
        hangul([0xC2E4, 0xD328]),
        hangul([0xCF00, 0xC774, 0xC2A4]),
        hangul([0xB300, 0xC751]),
        hangul([0xC911])
      ]
      |> Enum.join(" ")

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 Ourocode.CLI.launch(
                   [
                     "--prompt",
                     "ooo pm " <> spaced_goal,
                     "--format",
                     "json",
                     "--project-dir",
                     File.cwd!()
                   ],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: fn _prompt ->
                     flunk("headless pm workflow must not read terminal input")
                   end
                 )

        assert result.mode == :headless_prompt
      end)

    assert {:ok, evidence} = Ourocode.Json.decode(output)
    assert evidence["result"] =~ "ooo pm " <> expected_goal
    refute evidence["result"] =~ spaced_goal
  end

  test "headless ooo interview returns a distinct Socratic interview preview" do
    output =
      capture_io(fn ->
        assert {:ok, result} =
                 Ourocode.CLI.launch(
                   [
                     "--prompt",
                     "ooo interview improve first-start onboarding",
                     "--format",
                     "json",
                     "--project-dir",
                     File.cwd!()
                   ],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: fn _prompt ->
                     flunk("headless interview workflow must not read terminal input")
                   end
                 )

        assert result.mode == :headless_prompt
      end)

    assert {:ok, evidence} = Ourocode.Json.decode(output)
    assert evidence["action"]["kind"] == "guided_work"
    assert evidence["prompt_status"]["message"] =~ "Socratic interview preview"
    assert evidence["result"] =~ "Socratic interview preview"
    assert evidence["result"] =~ "Which uncertainty should this interview resolve first"
    assert evidence["result"] =~ "Clarify the user decision"
    assert evidence["result"] =~ "Clarify success criteria"
    refute evidence["result"] =~ "PM interview preview"
  end

  test "headless ooo auto returns a distinct plan and approval preview" do
    output =
      capture_io(fn ->
        assert {:ok, result} =
                 Ourocode.CLI.launch(
                   [
                     "--prompt",
                     "ooo auto improve first-start onboarding",
                     "--format",
                     "json",
                     "--project-dir",
                     File.cwd!()
                   ],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: fn _prompt ->
                     flunk("headless auto workflow must not read terminal input")
                   end
                 )

        assert result.mode == :headless_prompt
      end)

    assert {:ok, evidence} = Ourocode.Json.decode(output)
    assert evidence["action"]["kind"] == "guided_work"
    assert evidence["result"] =~ "Auto workflow:"
    assert evidence["result"] =~ "running plan:"
    assert evidence["result"] =~ "1. interview lane is open"
    assert evidence["result"] =~ "2. seed plan lane drafts"
    assert evidence["result"] =~ "3. approval checkpoint"
    assert evidence["result"] =~ "4. execution lane waits"
    assert evidence["result"] =~ "5. verify lane captures"
    assert evidence["result"] =~ "when opened in the TUI:"
    assert evidence["result"] =~ "/agents shows the auto lane"
    assert evidence["result"] =~ "/approve advances the reviewed sandbox execution"
    assert evidence["result"] =~ "this headless preview changes no project files"
    refute evidence["result"] =~ "Guided work is ready"
    refute evidence["result"] =~ "PM interview preview"
  end

  test "headless slash-prefixed ooo workflow matches prefix workflow behavior" do
    output =
      capture_io(fn ->
        assert {:ok, result} =
                 Ourocode.CLI.launch(
                   [
                     "--prompt",
                     "/ooo pm build onboarding",
                     "--format",
                     "json",
                     "--project-dir",
                     File.cwd!()
                   ],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: fn _prompt ->
                     flunk("headless slash-prefixed workflow must not read terminal input")
                   end
                 )

        assert result.mode == :headless_prompt
      end)

    assert {:ok, evidence} = Ourocode.Json.decode(output)
    assert evidence["prompt"] == "/ooo pm build onboarding"
    assert evidence["action"]["kind"] == "guided_work"
    assert evidence["prompt_status"]["executed"] == true
    assert evidence["result"] =~ "PM interview preview"
    assert evidence["result"] =~ "ooo pm build onboarding"
    assert evidence["result"] =~ "round 2:"
    refute evidence["action"]["command"] == "/ooo"
    refute evidence["result"] == ""
  end

  test "headless slash-prefixed bare ooo shows guided workflow help" do
    output =
      capture_io(fn ->
        assert {:ok, result} =
                 Ourocode.CLI.launch(
                   [
                     "--prompt",
                     "/ooo",
                     "--format",
                     "json",
                     "--project-dir",
                     File.cwd!()
                   ],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: fn _prompt ->
                     flunk("headless slash-prefixed ooo help must not read terminal input")
                   end
                 )

        assert result.mode == :headless_prompt
      end)

    assert {:ok, evidence} = Ourocode.Json.decode(output)
    assert evidence["action"]["kind"] == "guided_work"
    assert evidence["result"] =~ "Ourocode guided work"
    assert evidence["result"] =~ "ooo pm <goal>"
    assert evidence["result"] =~ "ooo interview <goal>"
    assert evidence["result"] =~ "ooo auto <goal>"
    refute evidence["result"] == ""
  end

  test "headless slash command prompt executes locally instead of invoking the model" do
    original_headless_model = Process.get(:ourocode_headless_model)

    Process.put(:ourocode_headless_model, %Ourocode.Model{
      id: :must_not_run,
      label: "must not run",
      kind: :cli,
      status: :ready,
      run: fn _prompt, _opts, _on_chunk -> flunk("slash commands must not run a model") end
    })

    on_exit(fn ->
      restore_process_value(:ourocode_headless_model, original_headless_model)
    end)

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 Ourocode.CLI.launch(
                   [
                     "--prompt",
                     "/children",
                     "--format",
                     "json",
                     "--project-dir",
                     File.cwd!()
                   ],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: fn _prompt ->
                     flunk("headless slash command must not read terminal input")
                   end
                 )

        assert result.mode == :headless_prompt
      end)

    assert {:ok, evidence} = Ourocode.Json.decode(output)
    assert evidence["prompt"] == "/children"
    assert evidence["action"]["kind"] == "command"
    assert evidence["action"]["command"] == "/children"
    assert evidence["prompt_status"]["executed"] == true
    assert evidence["prompt_status"]["message"] == "Slash command /children executed locally."
    assert evidence["result"] =~ "sessions: 0 active"
    assert evidence["result"] =~ "no delegated work yet"
    refute evidence["model"]

    assert Enum.map(evidence["events"], & &1["type"]) == [
             "accepted",
             "ready",
             "command",
             "completed"
           ]
  end

  test "headless management commands expose structured workspace models" do
    for {prompt, kind} <- [
          {"/plugins", "plugins"},
          {"/mcps", "mcps"},
          {"/config", "config"},
          {"/sandbox", "sandbox"},
          {"/sessions", "sessions"},
          {"/resume", "resume"}
        ] do
      output =
        capture_io(fn ->
          assert {:ok, result} =
                   Ourocode.CLI.launch(
                     [
                       "--prompt",
                       prompt,
                       "--format",
                       "json",
                       "--project-dir",
                       File.cwd!()
                     ],
                     Ourocode.CLITest.InteractiveTerminalSpy,
                     read_line: fn _prompt ->
                       flunk("headless management command must not read terminal input")
                     end
                   )

          assert result.mode == :headless_prompt
        end)

      assert {:ok, evidence} = Ourocode.Json.decode(output)
      assert evidence["workspace"]["kind"] == kind
      assert is_list(evidence["workspace"]["records"])
      assert is_binary(evidence["workspace"]["title"])
      assert is_binary(evidence["workspace"]["status"])
      assert is_binary(evidence["workspace"]["next"])
      refute inspect(evidence["workspace"]) =~ "ouroboros-plugin"

      refute output =~ "runtime_session_id"
      refute output =~ "transport_supervisor"
      refute output =~ "plugins/ouroboros"
    end
  end

  test "headless preflight slash command returns deterministic command evidence" do
    output =
      capture_io(fn ->
        assert {:ok, result} =
                 Ourocode.CLI.launch(
                   [
                     "--prompt",
                     "/preflight ooo pm build onboarding",
                     "--format",
                     "json",
                     "--project-dir",
                     File.cwd!()
                   ],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: fn _prompt ->
                     flunk("headless preflight must not read terminal input")
                   end
                 )

        assert result.mode == :headless_prompt
      end)

    assert {:ok, evidence} = Ourocode.Json.decode(output)
    assert evidence["action"]["kind"] == "command"
    assert evidence["action"]["command"] == "/preflight"
    assert evidence["prompt_status"]["message"] == "Slash command /preflight executed locally."
    assert evidence["result"] =~ "preflight: ready"
    assert evidence["result"] =~ "command: ooo pm build onboarding"
    assert evidence["result"] =~ "action: start guided work"
    assert evidence["result"] =~ "execution: preview only"
    assert evidence["events"] |> Enum.any?(&(&1["type"] == "command"))
    refute evidence["result"] =~ "codex"
  end

  test "headless bare slash opens command discovery" do
    output =
      capture_io(fn ->
        assert {:ok, result} =
                 Ourocode.CLI.launch(
                   [
                     "--prompt",
                     "/",
                     "--format",
                     "json",
                     "--project-dir",
                     File.cwd!()
                   ],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: fn _prompt ->
                     flunk("headless bare slash must not read terminal input")
                   end
                 )

        assert result.mode == :headless_prompt
      end)

    assert {:ok, evidence} = Ourocode.Json.decode(output)
    assert evidence["prompt"] == "/"
    assert evidence["action"]["kind"] == "command"
    assert evidence["prompt_status"]["message"] == "Slash command /help executed locally."
    assert evidence["result"] =~ "help"
    assert evidence["result"] =~ "start here:"
    assert evidence["result"] =~ "ooo pm"
    assert evidence["result"] =~ "ooo interview"
    assert evidence["result"] =~ "ooo auto"
    assert evidence["result"] =~ "/help"
    assert evidence["result"] =~ "/config"
    assert evidence["result"] =~ "/theme"
    assert evidence["result"] =~ "/verify"
    refute evidence["result"] =~ "unknown command"
  end

  test "headless command discovery aliases execute locally instead of invoking the model" do
    original_headless_model = Process.get(:ourocode_headless_model)

    Process.put(:ourocode_headless_model, %Ourocode.Model{
      id: :must_not_run,
      label: "must not run",
      kind: :cli,
      status: :ready,
      run: fn _prompt, _opts, _on_chunk -> flunk("command aliases must not run a model") end
    })

    on_exit(fn ->
      restore_process_value(:ourocode_headless_model, original_headless_model)
    end)

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 Ourocode.CLI.launch(
                   [
                     "--prompt",
                     "commands",
                     "--format",
                     "json",
                     "--project-dir",
                     File.cwd!()
                   ],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: fn _prompt ->
                     flunk("headless command alias must not read terminal input")
                   end
                 )

        assert result.mode == :headless_prompt
      end)

    assert {:ok, evidence} = Ourocode.Json.decode(output)
    assert evidence["prompt"] == "commands"
    assert evidence["action"]["kind"] == "command"
    assert evidence["action"]["command"] == "/commands"
    assert evidence["prompt_status"]["message"] == "Slash command /commands executed locally."
    assert evidence["result"] =~ "commands:"
    assert evidence["result"] =~ "start here:"
    assert evidence["result"] =~ "ooo pm"
    assert evidence["result"] =~ "ooo interview"
    assert evidence["result"] =~ "ooo auto"
    assert evidence["result"] =~ "/config"
    assert evidence["result"] =~ "/theme"
    refute evidence["model"]
  end

  test "top-level commands flag opens command discovery" do
    output =
      capture_io(fn ->
        assert {:ok, result} =
                 Ourocode.CLI.launch(
                   ["--commands", "--format", "json", "--project-dir", File.cwd!()],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: fn _prompt ->
                     flunk("commands flag must not read terminal input")
                   end
                 )

        assert result.mode == :headless_prompt
      end)

    assert {:ok, evidence} = Ourocode.Json.decode(output)
    assert evidence["prompt"] == "/commands"
    assert evidence["action"]["command"] == "/commands"
    assert evidence["result"] =~ "commands:"
    assert evidence["result"] =~ "ooo pm"
    assert evidence["result"] =~ "/config"
    assert evidence["result"] =~ "/theme"
  end

  test "headless cancel without active work returns calm idle state" do
    output =
      capture_io(fn ->
        assert {:ok, result} =
                 Ourocode.CLI.launch(
                   ["--prompt", "/cancel", "--format", "json", "--project-dir", File.cwd!()],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: fn _prompt ->
                     flunk("headless cancel must not read terminal input")
                   end
                 )

        assert result.mode == :headless_prompt
      end)

    assert {:ok, evidence} = Ourocode.Json.decode(output)
    assert evidence["ok"] == true
    assert evidence["result"] =~ "cancel: no active work"
    assert evidence["result"] =~ "ooo pm <goal>"
    refute evidence["result"] =~ "focused_child_session_pane_not_found"
    refute evidence["error"]
  end

  test "headless verify slash command returns deterministic verification guidance" do
    output =
      capture_io(fn ->
        assert {:ok, result} =
                 Ourocode.CLI.launch(
                   [
                     "--prompt",
                     "/verify",
                     "--format",
                     "json",
                     "--project-dir",
                     File.cwd!()
                   ],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: fn _prompt ->
                     flunk("headless /verify must not read terminal input")
                   end
                 )

        assert result.mode == :headless_prompt
      end)

    assert {:ok, evidence} = Ourocode.Json.decode(output)
    assert evidence["action"]["command"] == "/verify"
    assert evidence["prompt_status"]["message"] == "Slash command /verify executed locally."
    assert evidence["result"] =~ "verify: passed"
    assert evidence["result"] =~ "checks: 22/22 passed"
    assert evidence["result"] =~ "agent workspace ready"
    assert evidence["result"] =~ "guided interview ready"
    assert evidence["result"] =~ "terminal UI ready"
    refute evidence["result"] =~ "active_agents_lane_surface"

    assert Enum.any?(
             evidence["events"],
             &(&1["type"] == "check" and &1["name"] == "terminal UI ready")
           )
  end

  defp restore_env(key, nil), do: Application.delete_env(:ourocode, key)
  defp restore_env(key, value), do: Application.put_env(:ourocode, key, value)

  defp restore_process_value(key, nil), do: Process.delete(key)
  defp restore_process_value(key, value), do: Process.put(key, value)

  defp fake_headless_model(text) do
    %Ourocode.Model{
      id: :fake,
      label: "fake model",
      kind: :cli,
      status: :ready,
      run: fn _prompt, _opts, on_chunk ->
        on_chunk.(text)
        {:ok, text}
      end
    }
  end

  defp start_lines(lines) do
    {:ok, pid} = Agent.start_link(fn -> lines end)
    pid
  end

  defp next_line(lines) do
    fn _prompt ->
      Agent.get_and_update(lines, fn
        [] -> {nil, []}
        [line | rest] -> {line, rest}
      end)
    end
  end

  defp unique_id do
    System.unique_integer([:positive, :monotonic])
  end

  defp tmp_project_dir!(name) do
    dir = Path.join(System.tmp_dir!(), "#{name}-#{unique_id()}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    Process.put({__MODULE__, :tmp_project_dir}, dir)
    dir
  end

  defp cleanup_tmp_project_dir do
    case Process.get({__MODULE__, :tmp_project_dir}) do
      nil -> :ok
      dir -> File.rm_rf!(dir)
    end
  end

  defp plugin_config_json do
    """
    {
      "plugins": [
        {
          "identity": {
            "id": "ouroboros-plugin",
            "version": "1.0.0"
          },
          "path": "plugins/ouroboros",
          "entrypoint": {"type": "manifest", "path": "capabilities.json"},
          "enabled": true,
          "source": "official",
          "permissions": {
            "filesystem": [],
            "network": [],
            "process": []
          },
          "trust_policy": {
            "tier": "official",
            "requires_explicit_approval": false
          },
          "config": {
            "commands": true,
            "skills": true
          }
        }
      ]
    }
    """
  end

  defp hangul(codepoints) do
    codepoints
    |> Enum.map(&<<&1::utf8>>)
    |> Enum.join()
  end
end
