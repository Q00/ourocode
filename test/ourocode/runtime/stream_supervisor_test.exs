defmodule Ourocode.Runtime.StreamSupervisorTest do
  use ExUnit.Case, async: false

  alias Ourocode.Config
  alias Ourocode.Dashboard.ChildSessionPanes
  alias Ourocode.MCP.Transport.StreamableHTTP
  alias Ourocode.Runtime.Stream.{Child, Session, Transport}
  alias Ourocode.Runtime.Stream.Telemetry
  alias Ourocode.Test.PortPrograms

  setup do
    original_stream_mailbox_capacity = Application.get_env(:ourocode, :stream_mailbox_capacity)

    original_stream_mailbox_overflow_path =
      Application.get_env(:ourocode, :stream_mailbox_overflow_path)

    original_stream_mailbox_backpressure_threshold =
      Application.get_env(:ourocode, :stream_mailbox_backpressure_threshold)

    original_stream_mailbox_backpressure_behavior =
      Application.get_env(:ourocode, :stream_mailbox_backpressure_behavior)

    original_stream_mailbox_backpressure_delay_ms =
      Application.get_env(:ourocode, :stream_mailbox_backpressure_delay_ms)

    original_stale_cleanup_timeout_ms = Application.get_env(:ourocode, :stale_cleanup_timeout_ms)

    original_stream_subscription_cleanup_timeout_ms =
      Application.get_env(:ourocode, :stream_subscription_cleanup_timeout_ms)

    on_exit(fn ->
      restore_env(:stream_mailbox_capacity, original_stream_mailbox_capacity)
      restore_env(:stream_mailbox_overflow_path, original_stream_mailbox_overflow_path)

      restore_env(
        :stream_mailbox_backpressure_threshold,
        original_stream_mailbox_backpressure_threshold
      )

      restore_env(
        :stream_mailbox_backpressure_behavior,
        original_stream_mailbox_backpressure_behavior
      )

      restore_env(
        :stream_mailbox_backpressure_delay_ms,
        original_stream_mailbox_backpressure_delay_ms
      )

      restore_env(:stale_cleanup_timeout_ms, original_stale_cleanup_timeout_ms)

      restore_env(
        :stream_subscription_cleanup_timeout_ms,
        original_stream_subscription_cleanup_timeout_ms
      )
    end)
  end

  test "child, session, and transport stream processes start under an OTP supervisor" do
    supervisor =
      start_stream_supervisor!([
        {Transport,
         [
           id: :transport_stream,
           transport: :stdio,
           parent_call_id: "parent-supervised-1",
           runtime_source: "synthetic",
           external_ids: %{"session_id" => "session-supervised-1"}
         ]},
        {Session,
         [
           id: :session_stream,
           session_id: "session-supervised-1",
           runtime_source: "synthetic",
           external_ids: %{"session_id" => "session-supervised-1"}
         ]},
        {Child,
         [
           id: :child_stream,
           child_id: "child-supervised-1",
           parent_call_id: "parent-supervised-1",
           runtime_source: "synthetic",
           transport: :stdio,
           external_ids: %{"session_id" => "session-supervised-1"}
         ]},
        {StreamableHTTP,
         [
           id: :streamable_http_transport,
           url: "http://127.0.0.1:9/mcp",
           parent_call_id: "parent-http-supervised-1",
           runtime_source: "synthetic",
           external_ids: %{"session_id" => "session-http-supervised-1"}
         ]}
      ])

    children = Supervisor.which_children(supervisor)

    assert {:transport_stream, transport_pid, :worker, [Transport]} =
             Enum.find(children, &match?({:transport_stream, _pid, :worker, [Transport]}, &1))

    assert {:session_stream, session_pid, :worker, [Session]} =
             Enum.find(children, &match?({:session_stream, _pid, :worker, [Session]}, &1))

    assert {:child_stream, child_pid, :worker, [Child]} =
             Enum.find(children, &match?({:child_stream, _pid, :worker, [Child]}, &1))

    assert {:streamable_http_transport, http_pid, :worker, [StreamableHTTP]} =
             Enum.find(
               children,
               &match?({:streamable_http_transport, _pid, :worker, [StreamableHTTP]}, &1)
             )

    assert Process.alive?(transport_pid)
    assert Process.alive?(session_pid)
    assert Process.alive?(child_pid)
    assert Process.alive?(http_pid)

    Transport.record_event(transport_pid, %{
      event_seq: 1,
      transport: :stdio,
      parent_call_id: "parent-supervised-1"
    })

    Session.record_event(session_pid, %{
      event_seq: 1,
      runtime_source: "synthetic",
      external_ids: %{"session_id" => "session-supervised-1"}
    })

    Child.record_event(child_pid, %{
      event_seq: 1,
      transport: :stdio,
      parent_call_id: "parent-supervised-1",
      child_id: "child-supervised-1"
    })

    assert %{
             stream_kind: :transport,
             event_count: 1,
             stream_cursor: %{
               event_seq: 1,
               transport: :stdio,
               parent_call_id: "parent-supervised-1"
             }
           } = Transport.snapshot(transport_pid)

    assert %{
             stream_kind: :session,
             session_id: "session-supervised-1",
             event_count: 1,
             stream_cursor: %{event_seq: 1, session_id: "session-supervised-1"}
           } = Session.snapshot(session_pid)

    assert %{
             stream_kind: :child,
             child_id: "child-supervised-1",
             parent_call_id: "parent-supervised-1",
             event_count: 1,
             stream_cursor: %{
               event_seq: 1,
               child_id: "child-supervised-1",
               parent_call_id: "parent-supervised-1",
               transport: :stdio
             }
           } = Child.snapshot(child_pid)
  end

  test "stream supervision emits telemetry for stream start and normal stop events" do
    attach_stream_telemetry_handler()

    start_stream_supervisor!([
      {Transport,
       [
         id: :telemetry_transport_stream,
         transport: :stdio,
         parent_call_id: "parent-telemetry-1",
         runtime_source: "synthetic",
         external_ids: %{"session_id" => "session-telemetry-1"}
       ]},
      {Session,
       [
         id: :telemetry_session_stream,
         session_id: "session-telemetry-1",
         runtime_source: "synthetic",
         external_ids: %{"session_id" => "session-telemetry-1"}
       ]},
      {Child,
       [
         id: :telemetry_child_stream,
         child_id: "child-telemetry-1",
         parent_call_id: "parent-telemetry-1",
         runtime_source: "synthetic",
         transport: :stdio,
         external_ids: %{"session_id" => "session-telemetry-1"}
       ]}
    ])

    assert_receive {:telemetry_event, [:ourocode, :runtime, :stream, :start], measurements,
                    %{
                      stream_kind: :transport,
                      runtime_source: "synthetic",
                      transport: :stdio,
                      parent_call_id: "parent-telemetry-1",
                      external_ids: %{"session_id" => "session-telemetry-1"},
                      pid: transport_pid
                    }},
                   250

    assert is_integer(measurements.system_time)
    assert is_integer(measurements.monotonic_time)
    assert Process.alive?(transport_pid)

    assert_receive {:telemetry_event, [:ourocode, :runtime, :stream, :start], _measurements,
                    %{
                      stream_kind: :session,
                      runtime_source: "synthetic",
                      session_id: "session-telemetry-1",
                      external_ids: %{"session_id" => "session-telemetry-1"},
                      pid: session_pid
                    }},
                   250

    assert Process.alive?(session_pid)

    assert_receive {:telemetry_event, [:ourocode, :runtime, :stream, :start], _measurements,
                    %{
                      stream_kind: :child,
                      runtime_source: "synthetic",
                      transport: :stdio,
                      parent_call_id: "parent-telemetry-1",
                      child_id: "child-telemetry-1",
                      external_ids: %{"session_id" => "session-telemetry-1"},
                      pid: child_pid
                    }},
                   250

    assert Process.alive?(child_pid)

    assert :ok =
             Child.record_event(child_pid, %{
               event_seq: 1,
               child_id: "child-telemetry-1",
               parent_call_id: "parent-telemetry-1",
               transport: :stdio
             })

    assert %{event_count: 1, stream_cursor: %{event_seq: 1}} = Child.snapshot(child_pid)

    assert :ok = GenServer.stop(child_pid, :normal)

    assert_receive {:telemetry_event, [:ourocode, :runtime, :stream, :stop], stop_measurements,
                    %{
                      stream_kind: :child,
                      runtime_source: "synthetic",
                      transport: :stdio,
                      parent_call_id: "parent-telemetry-1",
                      child_id: "child-telemetry-1",
                      external_ids: %{"session_id" => "session-telemetry-1"},
                      stream_cursor: %{event_seq: 1},
                      event_count: 1,
                      stream_status: :active,
                      exit_reason: :normal,
                      exit_state: :normal,
                      pid: ^child_pid
                    }},
                   250

    assert is_integer(stop_measurements.system_time)
    assert is_integer(stop_measurements.monotonic_time)
  end

  test "stream supervision emits telemetry for stream crash events with stream and session metadata" do
    attach_stream_telemetry_handler()

    supervisor =
      start_stream_supervisor!([
        {Session,
         [
           id: :crashing_session_stream,
           restart: :temporary,
           session_id: "session-crash-1",
           runtime_source: "synthetic",
           external_ids: %{"session_id" => "session-crash-1", "job_id" => "job-crash-1"}
         ]},
        {Child,
         [
           id: :crashing_child_stream,
           restart: :temporary,
           child_id: "child-crash-1",
           parent_call_id: "parent-crash-1",
           runtime_source: "synthetic",
           transport: :sse,
           external_ids: %{"session_id" => "session-crash-1", "job_id" => "job-crash-1"},
           stream_mailbox_drain_interval_ms: :manual
         ]}
      ])

    session_pid = child_pid(supervisor, :crashing_session_stream)
    child_pid = child_pid(supervisor, :crashing_child_stream)

    assert :ok =
             Child.record_event(child_pid, %{
               event_seq: 7,
               transport: :sse,
               parent_call_id: "parent-crash-1",
               child_id: "child-crash-1"
             })

    send(child_pid, :drain_stream_mailbox)

    assert %{event_count: 1, stream_cursor: %{event_seq: 7}} = Child.snapshot(child_pid)

    child_ref = Process.monitor(child_pid)
    session_ref = Process.monitor(session_pid)

    :ok = :sys.terminate(child_pid, {:synthetic_crash, :child_stream_failed})
    :ok = :sys.terminate(session_pid, :synthetic_session_crash)

    assert_receive {:DOWN, ^child_ref, :process, ^child_pid,
                    {:synthetic_crash, :child_stream_failed}},
                   250

    assert_receive {:DOWN, ^session_ref, :process, ^session_pid, :synthetic_session_crash}, 250

    assert_receive {:telemetry_event, [:ourocode, :runtime, :stream, :crash], child_measurements,
                    %{
                      stream_kind: :child,
                      runtime_source: "synthetic",
                      transport: :sse,
                      parent_call_id: "parent-crash-1",
                      child_id: "child-crash-1",
                      external_ids: %{
                        "session_id" => "session-crash-1",
                        "job_id" => "job-crash-1"
                      },
                      stream_cursor: %{event_seq: 7},
                      event_count: 1,
                      exit_reason: {:synthetic_crash, :child_stream_failed},
                      crash_reason: {:synthetic_crash, :child_stream_failed},
                      exit_state: :error,
                      crash_state: :error,
                      pid: ^child_pid
                    }},
                   250

    assert is_integer(child_measurements.system_time)
    assert is_integer(child_measurements.monotonic_time)

    assert_receive {:telemetry_event, [:ourocode, :runtime, :stream, :crash],
                    _session_measurements,
                    %{
                      stream_kind: :session,
                      runtime_source: "synthetic",
                      session_id: "session-crash-1",
                      external_ids: %{
                        "session_id" => "session-crash-1",
                        "job_id" => "job-crash-1"
                      },
                      event_count: 0,
                      exit_reason: :synthetic_session_crash,
                      crash_reason: :synthetic_session_crash,
                      exit_state: :error,
                      crash_state: :error,
                      pid: ^session_pid
                    }},
                   250
  end

  test "restartable crashed stream process restarts while sibling streams remain alive" do
    supervisor =
      start_stream_supervisor!([
        {Transport,
         [
           id: :transport_stream,
           transport: :sse,
           parent_call_id: "parent-restart-1",
           runtime_source: "synthetic",
           external_ids: %{"session_id" => "session-restart-1"}
         ]},
        {Session,
         [
           id: :session_stream,
           session_id: "session-restart-1",
           runtime_source: "synthetic",
           external_ids: %{"session_id" => "session-restart-1"}
         ]},
        {Child,
         [
           id: :restartable_child_stream,
           restart: :permanent,
           child_id: "child-restart-1",
           parent_call_id: "parent-restart-1",
           runtime_source: "synthetic",
           transport: :sse,
           external_ids: %{"session_id" => "session-restart-1"}
         ]}
      ])

    transport_pid = child_pid(supervisor, :transport_stream)
    session_pid = child_pid(supervisor, :session_stream)
    crashed_child_pid = child_pid(supervisor, :restartable_child_stream)

    Transport.record_event(transport_pid, %{
      event_seq: 1,
      transport: :sse,
      parent_call_id: "parent-restart-1"
    })

    Session.record_event(session_pid, %{
      event_seq: 1,
      runtime_source: "synthetic",
      external_ids: %{"session_id" => "session-restart-1"}
    })

    crash_ref = Process.monitor(crashed_child_pid)
    Process.exit(crashed_child_pid, :synthetic_crash)
    assert_receive {:DOWN, ^crash_ref, :process, ^crashed_child_pid, :synthetic_crash}

    restarted_child_pid =
      eventually(fn ->
        case child_pid(supervisor, :restartable_child_stream) do
          pid when is_pid(pid) and pid != crashed_child_pid ->
            if Process.alive?(pid), do: {:ok, pid}, else: :retry

          _pid ->
            :retry
        end
      end)

    assert Process.alive?(transport_pid)
    assert Process.alive?(session_pid)
    assert child_pid(supervisor, :transport_stream) == transport_pid
    assert child_pid(supervisor, :session_stream) == session_pid

    assert %{
             stream_kind: :transport,
             event_count: 1,
             stream_cursor: %{
               event_seq: 1,
               transport: :sse,
               parent_call_id: "parent-restart-1"
             }
           } = Transport.snapshot(transport_pid)

    assert %{
             stream_kind: :session,
             session_id: "session-restart-1",
             event_count: 1,
             stream_cursor: %{event_seq: 1, session_id: "session-restart-1"}
           } = Session.snapshot(session_pid)

    Child.record_event(restarted_child_pid, %{
      event_seq: 2,
      transport: :sse,
      parent_call_id: "parent-restart-1",
      child_id: "child-restart-1"
    })

    assert %{
             stream_kind: :child,
             child_id: "child-restart-1",
             parent_call_id: "parent-restart-1",
             event_count: 1,
             stream_cursor: %{
               event_seq: 2,
               child_id: "child-restart-1",
               parent_call_id: "parent-restart-1",
               transport: :sse
             }
           } = Child.snapshot(restarted_child_pid)
  end

  test "non-restartable shutdown stream process terminates without restarting while siblings remain alive" do
    supervisor =
      start_stream_supervisor!([
        {Transport,
         [
           id: :transport_stream,
           transport: :streamable_http,
           parent_call_id: "parent-shutdown-1",
           runtime_source: "synthetic",
           external_ids: %{"session_id" => "session-shutdown-1"}
         ]},
        {Session,
         [
           id: :session_stream,
           session_id: "session-shutdown-1",
           runtime_source: "synthetic",
           external_ids: %{"session_id" => "session-shutdown-1"}
         ]},
        {Child,
         [
           id: :non_restartable_child_stream,
           restart: :temporary,
           child_id: "child-shutdown-1",
           parent_call_id: "parent-shutdown-1",
           runtime_source: "synthetic",
           transport: :streamable_http,
           external_ids: %{"session_id" => "session-shutdown-1"}
         ]}
      ])

    transport_pid = child_pid(supervisor, :transport_stream)
    session_pid = child_pid(supervisor, :session_stream)
    shutdown_child_pid = child_pid(supervisor, :non_restartable_child_stream)

    shutdown_ref = Process.monitor(shutdown_child_pid)
    Process.exit(shutdown_child_pid, :shutdown)
    assert_receive {:DOWN, ^shutdown_ref, :process, ^shutdown_child_pid, :shutdown}

    Process.sleep(50)

    eventually(fn ->
      case child_pid(supervisor, :non_restartable_child_stream) do
        pid when is_pid(pid) and pid != shutdown_child_pid ->
          if Process.alive?(pid), do: :retry, else: {:ok, :not_restarted}

        _pid ->
          {:ok, :not_restarted}
      end
    end)

    assert Process.alive?(transport_pid)
    assert Process.alive?(session_pid)
    assert child_pid(supervisor, :transport_stream) == transport_pid
    assert child_pid(supervisor, :session_stream) == session_pid

    Transport.record_event(transport_pid, %{
      event_seq: 2,
      transport: :streamable_http,
      parent_call_id: "parent-shutdown-1"
    })

    Session.record_event(session_pid, %{
      event_seq: 2,
      runtime_source: "synthetic",
      external_ids: %{"session_id" => "session-shutdown-1"}
    })

    assert %{
             stream_kind: :transport,
             event_count: 1,
             stream_cursor: %{
               event_seq: 2,
               transport: :streamable_http,
               parent_call_id: "parent-shutdown-1"
             }
           } = Transport.snapshot(transport_pid)

    assert %{
             stream_kind: :session,
             session_id: "session-shutdown-1",
             event_count: 1,
             stream_cursor: %{event_seq: 2, session_id: "session-shutdown-1"}
           } = Session.snapshot(session_pid)
  end

  test "inactivity timeout marks idle streams stale and triggers cleanup after elapsed idle window" do
    supervisor =
      start_stream_supervisor!([
        {Transport,
         [
           id: :idle_transport_stream,
           restart: :temporary,
           transport: :stdio,
           parent_call_id: "parent-idle-1",
           runtime_source: "synthetic",
           external_ids: %{"session_id" => "session-idle-1"},
           stale_cleanup_timeout_ms: 30,
           stream_cleanup_target: self(),
           stream_mailbox_drain_interval_ms: :manual
         ]},
        {Session,
         [
           id: :idle_session_stream,
           restart: :temporary,
           session_id: "session-idle-1",
           runtime_source: "synthetic",
           external_ids: %{"session_id" => "session-idle-1"},
           stale_cleanup_timeout_ms: 30,
           stream_cleanup_target: self(),
           stream_mailbox_drain_interval_ms: :manual
         ]},
        {Child,
         [
           id: :idle_child_stream,
           restart: :temporary,
           child_id: "child-idle-1",
           parent_call_id: "parent-idle-1",
           runtime_source: "synthetic",
           transport: :stdio,
           external_ids: %{"session_id" => "session-idle-1"},
           stale_cleanup_timeout_ms: 30,
           stream_cleanup_target: self(),
           stream_mailbox_drain_interval_ms: :manual
         ]}
      ])

    idle_transport_pid = child_pid(supervisor, :idle_transport_stream)
    idle_session_pid = child_pid(supervisor, :idle_session_stream)
    idle_child_pid = child_pid(supervisor, :idle_child_stream)
    idle_transport_ref = Process.monitor(idle_transport_pid)
    idle_session_ref = Process.monitor(idle_session_pid)
    idle_ref = Process.monitor(idle_child_pid)

    cleanups = receive_cleanups(3)

    assert %{
             cleanup_reason: :idle_timeout,
             stream_kind: :transport,
             runtime_source: "synthetic",
             transport: :stdio,
             parent_call_id: "parent-idle-1",
             external_ids: %{"session_id" => "session-idle-1"},
             idle_elapsed_ms: transport_elapsed_ms,
             stale_cleanup_timeout_ms: 30
           } = Map.fetch!(cleanups, :transport)

    assert %{
             cleanup_reason: :idle_timeout,
             stream_kind: :session,
             runtime_source: "synthetic",
             session_id: "session-idle-1",
             external_ids: %{"session_id" => "session-idle-1"},
             idle_elapsed_ms: session_elapsed_ms,
             stale_cleanup_timeout_ms: 30
           } = Map.fetch!(cleanups, :session)

    assert %{
             cleanup_reason: :idle_timeout,
             stream_kind: :child,
             runtime_source: "synthetic",
             transport: :stdio,
             parent_call_id: "parent-idle-1",
             child_id: "child-idle-1",
             external_ids: %{"session_id" => "session-idle-1"},
             idle_elapsed_ms: child_elapsed_ms,
             stale_cleanup_timeout_ms: 30
           } = Map.fetch!(cleanups, :child)

    assert transport_elapsed_ms >= 30
    assert session_elapsed_ms >= 30
    assert child_elapsed_ms >= 30
    assert_receive {:DOWN, ^idle_transport_ref, :process, ^idle_transport_pid, :normal}, 250
    assert_receive {:DOWN, ^idle_session_ref, :process, ^idle_session_pid, :normal}, 250
    assert_receive {:DOWN, ^idle_ref, :process, ^idle_child_pid, :normal}, 250

    eventually(fn ->
      cleaned? =
        [:idle_transport_stream, :idle_session_stream, :idle_child_stream]
        |> Enum.map(&child_pid(supervisor, &1))
        |> Enum.all?(fn
          pid when is_pid(pid) -> not Process.alive?(pid)
          _pid -> true
        end)

      if cleaned? do
        {:ok, :cleaned}
      else
        :retry
      end
    end)
  end

  test "default-config stdio child workload terminates spawned session and child processes within configured cleanup timeout" do
    Application.put_env(:ourocode, :stale_cleanup_timeout_ms, 40)
    configured_timeout_ms = Config.defaults().stale_cleanup_timeout_ms
    termination_budget_ms = configured_timeout_ms + 250

    supervisor =
      start_stream_supervisor!([
        {Session,
         [
           id: :default_config_stdio_session,
           restart: :temporary,
           session_id: "session-default-cleanup-1",
           runtime_source: "synthetic",
           external_ids: %{"session_id" => "session-default-cleanup-1"},
           stream_cleanup_target: self(),
           stream_lifecycle_target: self(),
           stream_mailbox_drain_interval_ms: :manual
         ]},
        {Child,
         [
           id: :default_config_stdio_child,
           restart: :temporary,
           child_id: "child-default-cleanup-1",
           parent_call_id: "parent-default-cleanup-1",
           runtime_source: "synthetic",
           transport: :stdio,
           external_ids: %{
             "session_id" => "session-default-cleanup-1",
             "childID" => "child-default-cleanup-1"
           },
           stream_cleanup_target: self(),
           stream_lifecycle_target: self(),
           stream_mailbox_drain_interval_ms: :manual
         ]}
      ])

    session_pid = child_pid(supervisor, :default_config_stdio_session)
    child_pid = child_pid(supervisor, :default_config_stdio_child)

    assert %{stream_stale_cleanup_timeout_ms: ^configured_timeout_ms} =
             Session.snapshot(session_pid)

    assert %{stream_stale_cleanup_timeout_ms: ^configured_timeout_ms, transport: :stdio} =
             Child.snapshot(child_pid)

    {:ok, pane_state} =
      ChildSessionPanes.register_child_pane(ChildSessionPanes.new(), %{
        child_id: "child-default-cleanup-1",
        parent_call_id: "parent-default-cleanup-1",
        runtime_source: "synthetic",
        transport: :stdio,
        external_ids: %{
          "session_id" => "session-default-cleanup-1",
          "childID" => "child-default-cleanup-1"
        },
        stream_cursor: %{
          transport: :stdio,
          child_id: "child-default-cleanup-1",
          parent_call_id: "parent-default-cleanup-1"
        },
        pane_state: %{stream_entries: [%{event_seq: 1, token: "cleanup"}]}
      })

    assert %{
             empty?: false,
             focused: "child-session:child-default-cleanup-1",
             open: ["child-session:child-default-cleanup-1"],
             working: [
               %{
                 child_id: "child-default-cleanup-1",
                 transport: "stdio",
                 stream_event_count: 1
               }
             ],
             completed: []
           } = ChildSessionPanes.render(pane_state)

    session_ref = Process.monitor(session_pid)
    child_ref = Process.monitor(child_pid)
    started_at = System.monotonic_time(:millisecond)

    cleanups = receive_cleanups(2, termination_budget_ms)

    assert %{
             cleanup_reason: :idle_timeout,
             stream_kind: :session,
             runtime_source: "synthetic",
             session_id: "session-default-cleanup-1",
             external_ids: %{"session_id" => "session-default-cleanup-1"},
             idle_elapsed_ms: session_elapsed_ms,
             stale_cleanup_timeout_ms: ^configured_timeout_ms
           } = Map.fetch!(cleanups, :session)

    assert %{
             cleanup_reason: :idle_timeout,
             stream_kind: :child,
             runtime_source: "synthetic",
             transport: :stdio,
             parent_call_id: "parent-default-cleanup-1",
             child_id: "child-default-cleanup-1",
             external_ids: %{
               "session_id" => "session-default-cleanup-1",
               "childID" => "child-default-cleanup-1"
             },
             idle_elapsed_ms: child_elapsed_ms,
             stale_cleanup_timeout_ms: ^configured_timeout_ms
           } = Map.fetch!(cleanups, :child)

    child_cleanup = Map.fetch!(cleanups, :child)
    cleaned_pane_state = ChildSessionPanes.apply_event(pane_state, child_cleanup)

    assert %{
             empty?: true,
             focused: nil,
             open: [],
             working: [],
             completed: [],
             child_pane_registry: %{}
           } = ChildSessionPanes.render(cleaned_pane_state)

    assert session_elapsed_ms >= configured_timeout_ms
    assert child_elapsed_ms >= configured_timeout_ms

    assert_receive {:stream_lifecycle_event,
                    %{
                      lifecycle_type: :stream_terminated,
                      exit_state: :normal,
                      exit_reason: :idle_timeout,
                      cleanup_reason: :idle_timeout,
                      stream_kind: :session,
                      session_id: "session-default-cleanup-1"
                    }},
                   termination_budget_ms

    assert_receive {:stream_lifecycle_event,
                    %{
                      lifecycle_type: :stream_terminated,
                      exit_state: :normal,
                      exit_reason: :idle_timeout,
                      cleanup_reason: :idle_timeout,
                      stream_kind: :child,
                      transport: :stdio,
                      child_id: "child-default-cleanup-1"
                    }},
                   termination_budget_ms

    assert_receive {:DOWN, ^session_ref, :process, ^session_pid, :normal},
                   termination_budget_ms

    assert_receive {:DOWN, ^child_ref, :process, ^child_pid, :normal}, termination_budget_ms

    terminated_elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert terminated_elapsed_ms <= termination_budget_ms

    eventually(fn ->
      cleaned? =
        [:default_config_stdio_session, :default_config_stdio_child]
        |> Enum.map(&child_pid(supervisor, &1))
        |> Enum.all?(fn
          pid when is_pid(pid) -> not Process.alive?(pid)
          _pid -> true
        end)

      if cleaned? do
        {:ok, :cleaned}
      else
        :retry
      end
    end)
  end

  test "default-config streamable HTTP child workload terminates BEAM processes and registered Ports within cleanup timeout" do
    Application.put_env(:ourocode, :stale_cleanup_timeout_ms, 100)
    configured_timeout_ms = Config.defaults().stale_cleanup_timeout_ms
    termination_budget_ms = configured_timeout_ms + 500
    {command, args} = PortPrograms.long_running_command()

    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        {:args, args},
        {:line, 65_536}
      ])

    supervisor =
      start_stream_supervisor!([
        {Session,
         [
           id: :default_config_streamable_http_session,
           restart: :temporary,
           session_id: "session-http-default-cleanup-1",
           runtime_source: "synthetic",
           external_ids: %{"session_id" => "session-http-default-cleanup-1"},
           stream_cleanup_target: self(),
           stream_lifecycle_target: self(),
           stream_mailbox_drain_interval_ms: :manual
         ]},
        {Child,
         [
           id: :default_config_streamable_http_child,
           restart: :temporary,
           child_id: "child-http-default-cleanup-1",
           parent_call_id: "parent-http-default-cleanup-1",
           runtime_source: "synthetic",
           transport: :streamable_http,
           external_ids: %{
             "session_id" => "session-http-default-cleanup-1",
             "childID" => "child-http-default-cleanup-1"
           },
           stream_cleanup_target: self(),
           stream_lifecycle_target: self(),
           stream_mailbox_drain_interval_ms: :manual
         ]}
      ])

    on_exit(fn -> close_port(port) end)

    session_pid = child_pid(supervisor, :default_config_streamable_http_session)
    child_pid = child_pid(supervisor, :default_config_streamable_http_child)

    assert %{stream_stale_cleanup_timeout_ms: ^configured_timeout_ms} =
             Session.snapshot(session_pid)

    assert %{
             stream_stale_cleanup_timeout_ms: ^configured_timeout_ms,
             transport: :streamable_http
           } = Child.snapshot(child_pid)

    assert Port.connect(port, child_pid)
    assert :ok = Child.register_resource(child_pid, :process_handle, port)

    assert %{
             stream_process_handles: [^port],
             stream_stale_cleanup_timeout_ms: ^configured_timeout_ms,
             transport: :streamable_http
           } = Child.snapshot(child_pid)

    session_ref = Process.monitor(session_pid)
    child_ref = Process.monitor(child_pid)
    started_at = System.monotonic_time(:millisecond)
    assert port_open?(port)

    cleanups = receive_cleanups(2, termination_budget_ms)

    assert %{
             cleanup_reason: :idle_timeout,
             stream_kind: :session,
             runtime_source: "synthetic",
             session_id: "session-http-default-cleanup-1",
             external_ids: %{"session_id" => "session-http-default-cleanup-1"},
             stale_cleanup_timeout_ms: ^configured_timeout_ms,
             released_resources: %{process_handles: 0}
           } = Map.fetch!(cleanups, :session)

    assert %{
             cleanup_reason: :idle_timeout,
             stream_kind: :child,
             runtime_source: "synthetic",
             transport: :streamable_http,
             parent_call_id: "parent-http-default-cleanup-1",
             child_id: "child-http-default-cleanup-1",
             external_ids: %{
               "session_id" => "session-http-default-cleanup-1",
               "childID" => "child-http-default-cleanup-1"
             },
             stale_cleanup_timeout_ms: ^configured_timeout_ms,
             released_resources: %{process_handles: 1}
           } = Map.fetch!(cleanups, :child)

    assert_receive {:stream_lifecycle_event,
                    %{
                      lifecycle_type: :stream_terminated,
                      exit_state: :normal,
                      exit_reason: :idle_timeout,
                      cleanup_reason: :idle_timeout,
                      stream_kind: :session,
                      session_id: "session-http-default-cleanup-1"
                    }},
                   termination_budget_ms

    assert_receive {:stream_lifecycle_event,
                    %{
                      lifecycle_type: :stream_terminated,
                      exit_state: :normal,
                      exit_reason: :idle_timeout,
                      cleanup_reason: :idle_timeout,
                      stream_kind: :child,
                      transport: :streamable_http,
                      child_id: "child-http-default-cleanup-1"
                    }},
                   termination_budget_ms

    assert_receive {:DOWN, ^session_ref, :process, ^session_pid, :normal},
                   termination_budget_ms

    assert_receive {:DOWN, ^child_ref, :process, ^child_pid, :normal}, termination_budget_ms
    refute port_open?(port)

    terminated_elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert terminated_elapsed_ms <= termination_budget_ms

    eventually(fn ->
      cleaned? =
        [:default_config_streamable_http_session, :default_config_streamable_http_child]
        |> Enum.map(&child_pid(supervisor, &1))
        |> Enum.all?(fn
          pid when is_pid(pid) -> not Process.alive?(pid)
          _pid -> true
        end)

      if cleaned? do
        {:ok, :cleaned}
      else
        :retry
      end
    end)
  end

  test "default-config SSE child agent/session workloads terminate spawned BEAM processes within cleanup timeout" do
    Application.put_env(:ourocode, :stale_cleanup_timeout_ms, 100)
    configured_timeout_ms = Config.defaults().stale_cleanup_timeout_ms
    termination_budget_ms = configured_timeout_ms + 500
    workload_count = Config.default_parallel_child_count()

    children =
      Enum.flat_map(1..workload_count, fn index ->
        session_id = "session-sse-default-cleanup-#{index}"
        child_id = "child-sse-default-cleanup-#{index}"
        parent_call_id = "parent-sse-default-cleanup-#{index}"

        [
          {:"default_config_sse_session_#{index}",
           [
             restart: :temporary,
             session_id: session_id,
             runtime_source: "synthetic",
             external_ids: %{"session_id" => session_id},
             stream_cleanup_target: self(),
             stream_lifecycle_target: self(),
             stream_mailbox_drain_interval_ms: :manual
           ]},
          {:"default_config_sse_child_#{index}",
           [
             restart: :temporary,
             child_id: child_id,
             parent_call_id: parent_call_id,
             runtime_source: "synthetic",
             transport: :sse,
             external_ids: %{"session_id" => session_id, "childID" => child_id},
             stream_cleanup_target: self(),
             stream_lifecycle_target: self(),
             stream_mailbox_drain_interval_ms: :manual
           ]}
        ]
      end)

    supervisor =
      children
      |> Enum.map(fn {id, opts} ->
        module =
          if id |> Atom.to_string() |> String.contains?("_session_") do
            Session
          else
            Child
          end

        {module, Keyword.put(opts, :id, id)}
      end)
      |> start_stream_supervisor!()

    {workload_processes, child_pane_state} =
      Enum.map(1..workload_count, fn index ->
        session_id = "session-sse-default-cleanup-#{index}"
        child_id = "child-sse-default-cleanup-#{index}"
        parent_call_id = "parent-sse-default-cleanup-#{index}"
        session_child_id = :"default_config_sse_session_#{index}"
        child_child_id = :"default_config_sse_child_#{index}"
        session_pid = child_pid(supervisor, session_child_id)
        child_pid = child_pid(supervisor, child_child_id)

        assert is_pid(session_pid)
        assert is_pid(child_pid)

        assert %{stream_stale_cleanup_timeout_ms: ^configured_timeout_ms} =
                 Session.snapshot(session_pid)

        assert %{stream_stale_cleanup_timeout_ms: ^configured_timeout_ms, transport: :sse} =
                 Child.snapshot(child_pid)

        assert :ok =
                 Session.record_event(session_pid, %{
                   event_seq: index * 2 - 1,
                   runtime_source: "synthetic",
                   external_ids: %{"session_id" => session_id}
                 })

        child_event = %{
          type: :parent_call_event,
          event_seq: index * 2,
          child_id: child_id,
          parent_call_id: parent_call_id,
          runtime_source: "synthetic",
          transport: :sse,
          external_ids: %{"session_id" => session_id, "childID" => child_id},
          notification: %{
            "method" => "notifications/progress",
            "params" => %{
              "childID" => child_id,
              "seq" => index,
              "token" => "cleanup-token-#{index}"
            }
          }
        }

        assert :ok = Child.record_event(child_pid, child_event)

        send(session_pid, :drain_stream_mailbox)
        send(child_pid, :drain_stream_mailbox)

        assert %{event_count: 1, stream_cursor: %{event_seq: session_event_seq}} =
                 Session.snapshot(session_pid)

        assert session_event_seq == index * 2 - 1

        assert %{
                 event_count: 1,
                 stream_cursor: %{
                   event_seq: child_event_seq,
                   child_id: ^child_id,
                   parent_call_id: ^parent_call_id,
                   transport: :sse
                 }
               } = Child.snapshot(child_pid)

        assert child_event_seq == index * 2

        {
          %{
            index: index,
            session_id: session_id,
            child_id: child_id,
            parent_call_id: parent_call_id,
            session_child_id: session_child_id,
            child_child_id: child_child_id,
            session_pid: session_pid,
            child_pid: child_pid,
            session_ref: Process.monitor(session_pid),
            child_ref: Process.monitor(child_pid)
          },
          child_event
        }
      end)
      |> Enum.unzip()

    child_pane_state =
      Enum.reduce(child_pane_state, ChildSessionPanes.new(), fn child_event, state ->
        ChildSessionPanes.apply_event(state, child_event)
      end)

    assert length(child_pane_state.working) == workload_count
    assert child_pane_state.completed == []
    assert length(child_pane_state.open) == workload_count

    started_at = System.monotonic_time(:millisecond)
    cleanups = receive_cleanup_list(workload_count * 2, termination_budget_ms)
    lifecycle_events = receive_lifecycle_list(workload_count * 2, termination_budget_ms)

    cleaned_child_pane_state =
      Enum.reduce(cleanups, child_pane_state, fn cleanup, state ->
        ChildSessionPanes.apply_event(state, cleanup)
      end)

    assert cleaned_child_pane_state.working == []
    assert cleaned_child_pane_state.completed == []
    assert cleaned_child_pane_state.open == []
    assert cleaned_child_pane_state.focused == nil
    assert cleaned_child_pane_state.child_pane_registry == %{}

    pane_cleanup_elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert pane_cleanup_elapsed_ms <= termination_budget_ms

    Enum.each(workload_processes, fn workload ->
      assert Enum.any?(cleanups, fn
               %{
                 cleanup_reason: :idle_timeout,
                 stream_kind: :session,
                 session_id: session_id,
                 transport: nil,
                 stale_cleanup_timeout_ms: ^configured_timeout_ms,
                 released_resources: %{pending_events: 0}
               } ->
                 session_id == workload.session_id

               _cleanup ->
                 false
             end)

      assert Enum.any?(cleanups, fn
               %{
                 cleanup_reason: :idle_timeout,
                 stream_kind: :child,
                 transport: :sse,
                 parent_call_id: parent_call_id,
                 child_id: child_id,
                 stale_cleanup_timeout_ms: ^configured_timeout_ms,
                 released_resources: %{pending_events: 0}
               } ->
                 child_id == workload.child_id and parent_call_id == workload.parent_call_id

               _cleanup ->
                 false
             end)

      assert Enum.any?(lifecycle_events, fn
               %{
                 lifecycle_type: :stream_terminated,
                 exit_state: :normal,
                 exit_reason: :idle_timeout,
                 cleanup_reason: :idle_timeout,
                 stream_kind: :session,
                 session_id: session_id
               } ->
                 session_id == workload.session_id

               _event ->
                 false
             end)

      assert Enum.any?(lifecycle_events, fn
               %{
                 lifecycle_type: :stream_terminated,
                 exit_state: :normal,
                 exit_reason: :idle_timeout,
                 cleanup_reason: :idle_timeout,
                 stream_kind: :child,
                 transport: :sse,
                 child_id: child_id
               } ->
                 child_id == workload.child_id

               _event ->
                 false
             end)

      session_ref = workload.session_ref
      session_pid = workload.session_pid
      child_ref = workload.child_ref
      child_pid = workload.child_pid

      assert_receive {:DOWN, ^session_ref, :process, ^session_pid, :normal}, termination_budget_ms
      assert_receive {:DOWN, ^child_ref, :process, ^child_pid, :normal}, termination_budget_ms
    end)

    terminated_elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert terminated_elapsed_ms <= termination_budget_ms

    eventually(fn ->
      cleaned? =
        Enum.all?(workload_processes, fn workload ->
          session_cleaned? =
            case child_pid(supervisor, workload.session_child_id) do
              pid when is_pid(pid) -> not Process.alive?(pid)
              _pid -> true
            end

          child_cleaned? =
            case child_pid(supervisor, workload.child_child_id) do
              pid when is_pid(pid) -> not Process.alive?(pid)
              _pid -> true
            end

          session_cleaned? and child_cleaned?
        end)

      if cleaned? do
        {:ok, :cleaned}
      else
        :retry
      end
    end)
  end

  test "default-config streamable HTTP child workload removes session and resource ETS entries during cleanup" do
    Application.put_env(:ourocode, :stale_cleanup_timeout_ms, 100)
    configured_timeout_ms = Config.defaults().stale_cleanup_timeout_ms
    termination_budget_ms = configured_timeout_ms + 500

    session_table = :ets.new(:streamable_http_session_ets_cleanup, [:public])
    resource_table = :ets.new(:streamable_http_resource_ets_cleanup, [:public])

    :ets.insert(session_table, [
      {{:session, "session-http-ets-cleanup-1"}, %{status: :working}},
      {{:cursor, "session-http-ets-cleanup-1"}, %{event_seq: 2}},
      {{:pane, "child-http-ets-cleanup-1"}, %{open?: true}}
    ])

    :ets.insert(resource_table, [
      {{:child, "child-http-ets-cleanup-1"}, %{parent_call_id: "parent-http-ets-cleanup-1"}},
      {{:stream_cursor, "child-http-ets-cleanup-1"}, %{event_seq: 3}},
      {{:token, 1}, "cleanup-token"},
      {{:resource, :subscription}, "streamable-http-subscription"}
    ])

    supervisor =
      start_stream_supervisor!([
        {Session,
         [
           id: :default_config_streamable_http_session_ets,
           restart: :temporary,
           session_id: "session-http-ets-cleanup-1",
           runtime_source: "synthetic",
           external_ids: %{"session_id" => "session-http-ets-cleanup-1"},
           stream_cleanup_target: self(),
           stream_lifecycle_target: self(),
           stream_mailbox_drain_interval_ms: :manual
         ]},
        {Child,
         [
           id: :default_config_streamable_http_child_ets,
           restart: :temporary,
           child_id: "child-http-ets-cleanup-1",
           parent_call_id: "parent-http-ets-cleanup-1",
           runtime_source: "synthetic",
           transport: :streamable_http,
           external_ids: %{
             "session_id" => "session-http-ets-cleanup-1",
             "childID" => "child-http-ets-cleanup-1"
           },
           stream_cleanup_target: self(),
           stream_lifecycle_target: self(),
           stream_mailbox_drain_interval_ms: :manual
         ]}
      ])

    on_exit(fn ->
      delete_ets_table(session_table)
      delete_ets_table(resource_table)
    end)

    session_pid = child_pid(supervisor, :default_config_streamable_http_session_ets)
    child_pid = child_pid(supervisor, :default_config_streamable_http_child_ets)

    assert :ok = Session.register_resource(session_pid, :buffer, {:ets, session_table})
    assert :ok = Child.register_resource(child_pid, :buffer, {:ets, resource_table})

    assert :ok =
             Session.record_event(session_pid, %{
               event_seq: 2,
               runtime_source: "synthetic",
               external_ids: %{"session_id" => "session-http-ets-cleanup-1"}
             })

    assert :ok =
             Child.record_event(child_pid, %{
               event_seq: 3,
               child_id: "child-http-ets-cleanup-1",
               parent_call_id: "parent-http-ets-cleanup-1",
               runtime_source: "synthetic",
               transport: :streamable_http,
               external_ids: %{
                 "session_id" => "session-http-ets-cleanup-1",
                 "childID" => "child-http-ets-cleanup-1"
               }
             })

    send(session_pid, :drain_stream_mailbox)
    send(child_pid, :drain_stream_mailbox)

    assert ets_size(session_table) == 3
    assert ets_size(resource_table) == 4

    assert %{
             stream_registered_buffers: [{:ets, ^session_table}],
             stream_stale_cleanup_timeout_ms: ^configured_timeout_ms,
             stream_cursor: %{event_seq: 2, session_id: "session-http-ets-cleanup-1"}
           } = Session.snapshot(session_pid)

    assert %{
             stream_registered_buffers: [{:ets, ^resource_table}],
             stream_stale_cleanup_timeout_ms: ^configured_timeout_ms,
             transport: :streamable_http,
             stream_cursor: %{
               event_seq: 3,
               child_id: "child-http-ets-cleanup-1",
               parent_call_id: "parent-http-ets-cleanup-1",
               transport: :streamable_http
             }
           } = Child.snapshot(child_pid)

    session_ref = Process.monitor(session_pid)
    child_ref = Process.monitor(child_pid)
    started_at = System.monotonic_time(:millisecond)

    cleanups = receive_cleanups(2, termination_budget_ms)

    assert %{
             cleanup_reason: :idle_timeout,
             stream_kind: :session,
             runtime_source: "synthetic",
             session_id: "session-http-ets-cleanup-1",
             external_ids: %{"session_id" => "session-http-ets-cleanup-1"},
             stream_cursor: %{event_seq: 2, session_id: "session-http-ets-cleanup-1"},
             stale_cleanup_timeout_ms: ^configured_timeout_ms,
             released_resources: %{registered_buffers: 1, ets_entries: 3}
           } = Map.fetch!(cleanups, :session)

    assert %{
             cleanup_reason: :idle_timeout,
             stream_kind: :child,
             runtime_source: "synthetic",
             transport: :streamable_http,
             parent_call_id: "parent-http-ets-cleanup-1",
             child_id: "child-http-ets-cleanup-1",
             external_ids: %{
               "session_id" => "session-http-ets-cleanup-1",
               "childID" => "child-http-ets-cleanup-1"
             },
             stream_cursor: %{
               event_seq: 3,
               child_id: "child-http-ets-cleanup-1",
               parent_call_id: "parent-http-ets-cleanup-1",
               transport: :streamable_http
             },
             stale_cleanup_timeout_ms: ^configured_timeout_ms,
             released_resources: %{registered_buffers: 1, ets_entries: 4}
           } = Map.fetch!(cleanups, :child)

    assert_receive {:stream_lifecycle_event,
                    %{
                      lifecycle_type: :stream_terminated,
                      exit_state: :normal,
                      exit_reason: :idle_timeout,
                      cleanup_reason: :idle_timeout,
                      stream_kind: :session,
                      session_id: "session-http-ets-cleanup-1",
                      released_resources: %{registered_buffers: 1, ets_entries: 3}
                    }},
                   termination_budget_ms

    assert_receive {:stream_lifecycle_event,
                    %{
                      lifecycle_type: :stream_terminated,
                      exit_state: :normal,
                      exit_reason: :idle_timeout,
                      cleanup_reason: :idle_timeout,
                      stream_kind: :child,
                      transport: :streamable_http,
                      child_id: "child-http-ets-cleanup-1",
                      released_resources: %{registered_buffers: 1, ets_entries: 4}
                    }},
                   termination_budget_ms

    assert_receive {:DOWN, ^session_ref, :process, ^session_pid, :normal},
                   termination_budget_ms

    assert_receive {:DOWN, ^child_ref, :process, ^child_pid, :normal}, termination_budget_ms

    eventually(fn ->
      if ets_size(session_table) == 0 and ets_size(resource_table) == 0 do
        {:ok, :ets_entries_removed}
      else
        :retry
      end
    end)

    removed_elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert removed_elapsed_ms <= termination_budget_ms
  end

  test "default-config streamable HTTP child workload unsubscribes stream subscriptions within cleanup timeout" do
    Application.put_env(:ourocode, :stale_cleanup_timeout_ms, 100)
    Application.put_env(:ourocode, :stream_subscription_cleanup_timeout_ms, 80)
    configured_timeout_ms = Config.defaults().stale_cleanup_timeout_ms
    configured_subscription_timeout_ms = Config.defaults().stream_subscription_cleanup_timeout_ms
    cleanup_budget_ms = configured_timeout_ms + configured_subscription_timeout_ms + 500

    session_subscription =
      start_subscription_probe(self(), :session_http_subscription_cleanup)

    child_subscription =
      start_subscription_probe(self(), :child_http_subscription_cleanup)

    supervisor =
      start_stream_supervisor!([
        {Session,
         [
           id: :default_config_streamable_http_session_subscription,
           restart: :temporary,
           session_id: "session-http-subscription-cleanup-1",
           runtime_source: "synthetic",
           external_ids: %{"session_id" => "session-http-subscription-cleanup-1"},
           stream_cleanup_target: self(),
           stream_lifecycle_target: self(),
           stream_mailbox_drain_interval_ms: :manual
         ]},
        {Child,
         [
           id: :default_config_streamable_http_child_subscription,
           restart: :temporary,
           child_id: "child-http-subscription-cleanup-1",
           parent_call_id: "parent-http-subscription-cleanup-1",
           runtime_source: "synthetic",
           transport: :streamable_http,
           external_ids: %{
             "session_id" => "session-http-subscription-cleanup-1",
             "childID" => "child-http-subscription-cleanup-1"
           },
           stream_cleanup_target: self(),
           stream_lifecycle_target: self(),
           stream_mailbox_drain_interval_ms: :manual
         ]}
      ])

    on_exit(fn ->
      stop_subscription_probe(session_subscription)
      stop_subscription_probe(child_subscription)
    end)

    session_pid = child_pid(supervisor, :default_config_streamable_http_session_subscription)
    child_pid = child_pid(supervisor, :default_config_streamable_http_child_subscription)

    assert :ok = Session.register_resource(session_pid, :subscription, session_subscription)
    assert :ok = Child.register_resource(child_pid, :subscription, child_subscription)

    send(session_subscription, {:source_event, :before_cleanup})
    send(child_subscription, {:source_event, :before_cleanup})

    assert_receive {:subscription_event, :session_http_subscription_cleanup, :before_cleanup}, 100
    assert_receive {:subscription_event, :child_http_subscription_cleanup, :before_cleanup}, 100

    assert %{
             stream_subscriptions: [^session_subscription],
             stream_stale_cleanup_timeout_ms: ^configured_timeout_ms,
             stream_subscription_cleanup_timeout_ms: ^configured_subscription_timeout_ms
           } = Session.snapshot(session_pid)

    assert %{
             stream_subscriptions: [^child_subscription],
             stream_stale_cleanup_timeout_ms: ^configured_timeout_ms,
             stream_subscription_cleanup_timeout_ms: ^configured_subscription_timeout_ms,
             transport: :streamable_http
           } = Child.snapshot(child_pid)

    session_ref = Process.monitor(session_pid)
    child_ref = Process.monitor(child_pid)
    started_at = System.monotonic_time(:millisecond)

    cleanups = receive_cleanups(2, cleanup_budget_ms)

    assert %{
             cleanup_reason: :idle_timeout,
             stream_kind: :session,
             runtime_source: "synthetic",
             session_id: "session-http-subscription-cleanup-1",
             external_ids: %{"session_id" => "session-http-subscription-cleanup-1"},
             stale_cleanup_timeout_ms: ^configured_timeout_ms,
             stream_subscription_cleanup_timeout_ms: ^configured_subscription_timeout_ms,
             released_resources: %{subscriptions: 1}
           } = Map.fetch!(cleanups, :session)

    assert %{
             cleanup_reason: :idle_timeout,
             stream_kind: :child,
             runtime_source: "synthetic",
             transport: :streamable_http,
             parent_call_id: "parent-http-subscription-cleanup-1",
             child_id: "child-http-subscription-cleanup-1",
             external_ids: %{
               "session_id" => "session-http-subscription-cleanup-1",
               "childID" => "child-http-subscription-cleanup-1"
             },
             stale_cleanup_timeout_ms: ^configured_timeout_ms,
             stream_subscription_cleanup_timeout_ms: ^configured_subscription_timeout_ms,
             released_resources: %{subscriptions: 1}
           } = Map.fetch!(cleanups, :child)

    assert_receive {:subscription_unsubscribed, :session_http_subscription_cleanup, ^session_pid},
                   configured_subscription_timeout_ms

    assert_receive {:subscription_unsubscribed, :child_http_subscription_cleanup, ^child_pid},
                   configured_subscription_timeout_ms

    assert_receive {:DOWN, ^session_ref, :process, ^session_pid, :normal}, cleanup_budget_ms
    assert_receive {:DOWN, ^child_ref, :process, ^child_pid, :normal}, cleanup_budget_ms

    send(session_subscription, {:source_event, :after_cleanup})
    send(child_subscription, {:source_event, :after_cleanup})

    refute_receive {:subscription_event, :session_http_subscription_cleanup, :after_cleanup}, 100
    refute_receive {:subscription_event, :child_http_subscription_cleanup, :after_cleanup}, 100

    terminated_elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert terminated_elapsed_ms <= cleanup_budget_ms
  end

  test "timeout cleanup emits telemetry with stale session and child cleanup metadata" do
    attach_stream_cleanup_telemetry_handler()

    {:ok, session_pid} =
      Session.start_link(
        session_id: "session-cleanup-telemetry-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-cleanup-telemetry-1"},
        stale_cleanup_timeout_ms: 30,
        stream_cleanup_action: :mark_stale,
        stream_mailbox_drain_interval_ms: :manual
      )

    {:ok, child_pid} =
      Child.start_link(
        child_id: "child-cleanup-telemetry-1",
        parent_call_id: "parent-cleanup-telemetry-1",
        runtime_source: "synthetic",
        transport: :sse,
        external_ids: %{
          "session_id" => "session-cleanup-telemetry-1",
          "childID" => "child-cleanup-telemetry-1"
        },
        stale_cleanup_timeout_ms: 30,
        stream_cleanup_action: :mark_stale,
        stream_mailbox_drain_interval_ms: :manual
      )

    on_exit(fn ->
      if Process.alive?(session_pid), do: GenServer.stop(session_pid)
      if Process.alive?(child_pid), do: GenServer.stop(child_pid)
    end)

    assert :ok =
             Child.record_event(child_pid, %{
               event_seq: 11,
               child_id: "child-cleanup-telemetry-1",
               parent_call_id: "parent-cleanup-telemetry-1",
               transport: :sse
             })

    assert :ok = Child.register_resource(child_pid, :process_handle, {:port, "runtime-port-1"})
    assert :ok = Child.register_resource(child_pid, :subscription, {:sse, "subscription-1"})
    assert :ok = Child.register_resource(child_pid, :buffer, {:parser_buffer, "partial-event"})

    cleanup_telemetry = receive_cleanup_telemetry_events(2)

    assert {session_measurements,
            %{
              cleanup_state: :completed,
              cleanup_reason: :idle_timeout,
              stream_kind: :session,
              stream_status: :stale,
              runtime_source: "synthetic",
              session_id: "session-cleanup-telemetry-1",
              external_ids: %{"session_id" => "session-cleanup-telemetry-1"},
              idle_elapsed_ms: session_elapsed_ms,
              stale_cleanup_timeout_ms: 30,
              released_resources: %{
                process_handles: 0,
                subscriptions: 0,
                registered_buffers: 0,
                pending_events: 0
              },
              pid: ^session_pid
            }} = Map.fetch!(cleanup_telemetry, :session)

    assert session_elapsed_ms >= 30
    assert session_measurements.idle_elapsed_ms >= 30
    assert session_measurements.stale_cleanup_timeout_ms == 30
    assert session_measurements.released_pending_events == 0

    assert {child_measurements,
            %{
              cleanup_state: :completed,
              cleanup_reason: :idle_timeout,
              stream_kind: :child,
              stream_status: :stale,
              runtime_source: "synthetic",
              transport: :sse,
              parent_call_id: "parent-cleanup-telemetry-1",
              child_id: "child-cleanup-telemetry-1",
              external_ids: %{
                "session_id" => "session-cleanup-telemetry-1",
                "childID" => "child-cleanup-telemetry-1"
              },
              idle_elapsed_ms: child_elapsed_ms,
              stale_cleanup_timeout_ms: 30,
              released_resources: %{
                process_handles: 1,
                subscriptions: 1,
                registered_buffers: 1,
                pending_events: 1
              },
              pid: ^child_pid
            }} = Map.fetch!(cleanup_telemetry, :child)

    assert child_elapsed_ms >= 30
    assert child_measurements.idle_elapsed_ms >= 30
    assert child_measurements.stale_cleanup_timeout_ms == 30
    assert child_measurements.released_process_handles == 1
    assert child_measurements.released_subscriptions == 1
    assert child_measurements.released_registered_buffers == 1
    assert child_measurements.released_pending_events == 1

    assert %{stream_status: :stale, stream_cleanup_reason: :idle_timeout} =
             Session.snapshot(session_pid)

    assert %{stream_status: :stale, stream_cleanup_reason: :idle_timeout} =
             Child.snapshot(child_pid)
  end

  test "operation timeout terminates a long-running active stream operation" do
    attach_stream_cleanup_telemetry_handler()

    {:ok, child_pid} =
      Child.start_link(
        child_id: "child-operation-timeout-1",
        parent_call_id: "parent-operation-timeout-1",
        runtime_source: "synthetic",
        transport: :stdio,
        external_ids: %{"session_id" => "session-operation-timeout-1"},
        operation_timeout_ms: 30,
        stale_cleanup_timeout_ms: 1_000,
        stream_lifecycle_target: self(),
        stream_operation_timeout_target: self(),
        stream_cleanup_target: self(),
        stream_mailbox_drain_interval_ms: :manual
      )

    on_exit(fn ->
      if Process.alive?(child_pid), do: GenServer.stop(child_pid)
    end)

    timeout_ref = Process.monitor(child_pid)

    assert :ok = Child.begin_operation(child_pid, "op-long-running-1")

    assert :ok =
             Child.record_event(child_pid, %{
               event_seq: 1,
               child_id: "child-operation-timeout-1",
               parent_call_id: "parent-operation-timeout-1",
               transport: :stdio
             })

    assert_receive {:stream_operation_timeout,
                    %{
                      cleanup_reason: :operation_timeout,
                      stream_kind: :child,
                      runtime_source: "synthetic",
                      transport: :stdio,
                      parent_call_id: "parent-operation-timeout-1",
                      child_id: "child-operation-timeout-1",
                      external_ids: %{"session_id" => "session-operation-timeout-1"},
                      operation_id: "op-long-running-1",
                      operation_elapsed_ms: operation_elapsed_ms,
                      operation_timeout_ms: 30,
                      stale_cleanup_timeout_ms: 1_000
                    }},
                   250

    assert operation_elapsed_ms >= 30

    assert_receive {:telemetry_event, [:ourocode, :runtime, :stream, :cleanup],
                    cleanup_measurements,
                    %{
                      cleanup_state: :completed,
                      cleanup_reason: :operation_timeout,
                      stream_kind: :child,
                      stream_status: :stale,
                      runtime_source: "synthetic",
                      transport: :stdio,
                      parent_call_id: "parent-operation-timeout-1",
                      child_id: "child-operation-timeout-1",
                      external_ids: %{"session_id" => "session-operation-timeout-1"},
                      operation_id: "op-long-running-1",
                      operation_elapsed_ms: telemetry_operation_elapsed_ms,
                      operation_timeout_ms: 30,
                      stale_cleanup_timeout_ms: 1_000,
                      released_resources: %{pending_events: 1},
                      pid: ^child_pid
                    }},
                   250

    assert telemetry_operation_elapsed_ms >= 30
    assert cleanup_measurements.operation_elapsed_ms >= 30
    assert cleanup_measurements.operation_timeout_ms == 30
    assert cleanup_measurements.stale_cleanup_timeout_ms == 1_000
    assert cleanup_measurements.released_pending_events == 1

    assert_receive {:DOWN, ^timeout_ref, :process, ^child_pid, :normal}, 250
  end

  test "child stream completion invokes the buffered event final flush exactly once" do
    {:ok, child_pid} =
      Child.start_link(
        child_id: "child-completion-final-flush-1",
        parent_call_id: "parent-completion-final-flush-1",
        runtime_source: "synthetic",
        transport: :stdio,
        external_ids: %{"session_id" => "session-completion-final-flush-1"},
        operation_timeout_ms: 1_000,
        stale_cleanup_timeout_ms: 10_000,
        stream_mailbox_drain_interval_ms: :manual,
        stream_mailbox_final_flush_target: self(),
        stream_mailbox_rendered_event_target: self()
      )

    on_exit(fn ->
      if Process.alive?(child_pid), do: GenServer.stop(child_pid)
    end)

    assert :ok = Child.begin_operation(child_pid, "op-completion-final-flush-1")

    assert :ok =
             Child.record_event(child_pid, %{
               event_seq: 1,
               child_id: "child-completion-final-flush-1",
               parent_call_id: "parent-completion-final-flush-1",
               transport: :stdio
             })

    assert :ok =
             Child.record_event(child_pid, %{
               event_seq: 2,
               child_id: "child-completion-final-flush-1",
               parent_call_id: "parent-completion-final-flush-1",
               transport: :stdio
             })

    assert %{
             event_count: 0,
             stream_mailbox_pending_count: 2,
             stream_mailbox_final_flush_count: 0,
             stream_completion_status: :streaming,
             stream_completion_cursor: nil
           } = Child.snapshot(child_pid)

    assert :ok = Child.complete_operation(child_pid, "op-completion-final-flush-1")

    assert_receive {:stream_mailbox_rendered_event,
                    %{
                      event_seq: 1,
                      child_id: "child-completion-final-flush-1",
                      parent_call_id: "parent-completion-final-flush-1",
                      transport: :stdio
                    }},
                   250

    assert_receive {:stream_mailbox_rendered_event,
                    %{
                      event_seq: 2,
                      child_id: "child-completion-final-flush-1",
                      parent_call_id: "parent-completion-final-flush-1",
                      transport: :stdio
                    }},
                   250

    assert_receive {:stream_mailbox_final_flush,
                    %{
                      reason: :stream_completed,
                      stream_kind: :child,
                      runtime_source: "synthetic",
                      transport: :stdio,
                      parent_call_id: "parent-completion-final-flush-1",
                      child_id: "child-completion-final-flush-1",
                      external_ids: %{"session_id" => "session-completion-final-flush-1"},
                      stream_cursor: %{
                        child_id: "child-completion-final-flush-1",
                        parent_call_id: "parent-completion-final-flush-1",
                        transport: :stdio,
                        event_seq: 2
                      },
                      flushed_pending_count: 2,
                      rendered_event_seqs: [1, 2],
                      pending_count: 0,
                      final_flush_count: 1,
                      completion_status: :completed,
                      completion_cursor: %{event_seq: 2}
                    }},
                   250

    assert %{
             event_count: 2,
             stream_mailbox_pending_count: 0,
             stream_mailbox_final_flush_count: 1,
             stream_completion_status: :completed,
             stream_completion_cursor: %{event_seq: 2},
             stream_cursor: %{event_seq: 2}
           } = Child.snapshot(child_pid)

    assert {:error, :operation_not_active} =
             Child.complete_operation(child_pid, "op-completion-final-flush-1")

    refute_receive {:stream_mailbox_final_flush, _flush}, 100

    assert %{
             event_count: 2,
             stream_mailbox_pending_count: 0,
             stream_mailbox_final_flush_count: 1
           } = Child.snapshot(child_pid)
  end

  test "transport stream emits every buffered normalized event to subscribers without sequence gaps" do
    {:ok, transport_pid} =
      Transport.start_link(
        transport: :sse,
        parent_call_id: "parent-buffered-subscriber-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-buffered-subscriber-1"},
        stream_mailbox_capacity: 8,
        stream_mailbox_drain_interval_ms: :manual,
        stream_event_subscribers: [self()]
      )

    on_exit(fn ->
      if Process.alive?(transport_pid), do: GenServer.stop(transport_pid)
    end)

    expected_sequence = Enum.to_list(1..5)

    Enum.each(expected_sequence, fn event_seq ->
      assert :ok =
               Transport.record_event(transport_pid, %{
                 event_seq: event_seq,
                 normalized_event_type: :mcp_transport_message,
                 transport: :sse,
                 parent_call_id: "parent-buffered-subscriber-1",
                 external_ids: %{"session_id" => "session-buffered-subscriber-1"},
                 payload: %{"delta" => "chunk-#{event_seq}"}
               })
    end)

    assert %{
             event_count: 0,
             stream_mailbox_pending_count: 5,
             stream_mailbox_overflow_count: 0
           } = Transport.snapshot(transport_pid)

    Enum.each(expected_sequence, fn _event_seq ->
      send(transport_pid, :drain_stream_mailbox)
    end)

    delivered_events = receive_stream_events(5, 250)
    delivered_sequence = Enum.map(delivered_events, & &1.event_seq)

    assert delivered_sequence == expected_sequence
    assert no_sequence_gaps?(delivered_sequence)

    assert Enum.all?(delivered_events, fn event ->
             event.transport == :sse and
               event.parent_call_id == "parent-buffered-subscriber-1" and
               event.normalized_event_type == :mcp_transport_message
           end)

    refute_receive {:stream_event, _event}, 50

    assert %{
             event_count: 5,
             stream_mailbox_pending_count: 0,
             stream_mailbox_overflow_count: 0,
             stream_cursor: %{
               event_seq: 5,
               transport: :sse,
               parent_call_id: "parent-buffered-subscriber-1"
             }
           } = Transport.snapshot(transport_pid)
  end

  defp start_stream_supervisor!(children) do
    {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

    on_exit(fn ->
      if Process.alive?(supervisor) do
        safe_stop_supervisor(supervisor)
      end
    end)

    supervisor
  end

  defp child_pid(supervisor, child_id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^child_id, pid, :worker, _modules} -> pid
      _child -> nil
    end)
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      {:ok, result} ->
        result

      :retry ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end

  defp eventually(fun, 0) do
    flunk("condition did not become true; last result: #{inspect(fun.())}")
  end

  defp port_open?(port) do
    !!Port.info(port)
  rescue
    ArgumentError -> false
  end

  defp close_port(port) do
    if port_open?(port) do
      Port.close(port)
    end
  rescue
    ArgumentError -> :ok
  end

  defp ets_size(table) do
    case :ets.info(table, :size) do
      size when is_integer(size) -> size
      :undefined -> 0
    end
  rescue
    ArgumentError -> 0
  end

  defp delete_ets_table(table) do
    if :ets.info(table) != :undefined do
      :ets.delete(table)
    end
  rescue
    ArgumentError -> :ok
  end

  defp start_subscription_probe(owner, name) do
    spawn_link(fn -> subscription_probe_loop(owner, name, true) end)
  end

  defp stop_subscription_probe(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      send(pid, :stop)
    end
  end

  defp subscription_probe_loop(owner, name, subscribed?) do
    receive do
      {:source_event, event} ->
        if subscribed? do
          send(owner, {:subscription_event, name, event})
        end

        subscription_probe_loop(owner, name, subscribed?)

      {:unsubscribe, stream_pid} ->
        send(owner, {:subscription_unsubscribed, name, stream_pid})
        subscription_probe_loop(owner, name, false)

      :stop ->
        :ok
    end
  end

  defp receive_cleanups(expected_count), do: receive_cleanups(expected_count, %{}, 250)

  defp receive_cleanups(expected_count, timeout_ms) when is_integer(timeout_ms),
    do: receive_cleanups(expected_count, %{}, timeout_ms)

  defp receive_cleanups(0, cleanups, _timeout_ms), do: cleanups

  defp receive_cleanups(expected_count, cleanups, timeout_ms) do
    receive do
      {:stream_stale_cleanup, %{stream_kind: stream_kind} = cleanup} ->
        receive_cleanups(expected_count - 1, Map.put(cleanups, stream_kind, cleanup), timeout_ms)
    after
      timeout_ms -> flunk("expected #{expected_count} more stale cleanup notification(s)")
    end
  end

  defp receive_cleanup_list(expected_count, timeout_ms),
    do: receive_cleanup_list(expected_count, [], timeout_ms)

  defp receive_cleanup_list(0, cleanups, _timeout_ms), do: Enum.reverse(cleanups)

  defp receive_cleanup_list(expected_count, cleanups, timeout_ms) do
    receive do
      {:stream_stale_cleanup, cleanup} ->
        receive_cleanup_list(expected_count - 1, [cleanup | cleanups], timeout_ms)
    after
      timeout_ms -> flunk("expected #{expected_count} more stale cleanup notification(s)")
    end
  end

  defp receive_lifecycle_list(expected_count, timeout_ms),
    do: receive_lifecycle_list(expected_count, [], timeout_ms)

  defp receive_lifecycle_list(0, events, _timeout_ms), do: Enum.reverse(events)

  defp receive_lifecycle_list(expected_count, events, timeout_ms) do
    receive do
      {:stream_lifecycle_event, event} ->
        receive_lifecycle_list(expected_count - 1, [event | events], timeout_ms)
    after
      timeout_ms -> flunk("expected #{expected_count} more stream lifecycle event(s)")
    end
  end

  defp receive_stream_events(expected_count, timeout_ms),
    do: receive_stream_events(expected_count, [], timeout_ms)

  defp receive_stream_events(0, events, _timeout_ms), do: Enum.reverse(events)

  defp receive_stream_events(expected_count, events, timeout_ms) do
    receive do
      {:stream_event, event} ->
        receive_stream_events(expected_count - 1, [event | events], timeout_ms)
    after
      timeout_ms -> flunk("expected #{expected_count} more stream event(s)")
    end
  end

  defp no_sequence_gaps?([]), do: true
  defp no_sequence_gaps?([_single]), do: true

  defp no_sequence_gaps?(sequence) do
    sequence
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [left, right] -> right == left + 1 end)
  end

  defp receive_cleanup_telemetry_events(expected_count),
    do: receive_cleanup_telemetry_events(expected_count, %{})

  defp receive_cleanup_telemetry_events(0, events), do: events

  defp receive_cleanup_telemetry_events(expected_count, events) do
    receive do
      {:telemetry_event, [:ourocode, :runtime, :stream, :cleanup], measurements,
       %{stream_kind: stream_kind} = metadata} ->
        receive_cleanup_telemetry_events(
          expected_count - 1,
          Map.put(events, stream_kind, {measurements, metadata})
        )
    after
      500 -> flunk("expected #{expected_count} more cleanup telemetry event(s)")
    end
  end

  defp attach_stream_telemetry_handler do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [Telemetry.start_event(), Telemetry.stop_event(), Telemetry.crash_event()],
        fn event_name, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp attach_stream_cleanup_telemetry_handler do
    handler_id = {__MODULE__, self(), :cleanup, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        Telemetry.cleanup_event(),
        fn event_name, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp safe_stop_supervisor(supervisor) when is_pid(supervisor) do
    if Process.alive?(supervisor) do
      Supervisor.stop(supervisor)
    end
  catch
    :exit, _reason -> :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:ourocode, key)
  defp restore_env(key, value), do: Application.put_env(:ourocode, key, value)
end
