defmodule Ourocode.MCP.Transport.StdioTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.{ChildSessionPanes, Layout, ParentMcpPane, UITree}
  alias Ourocode.Journal
  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.Stdio

  @parent_call_timeout_ms 5_000

  test "executes a parent call and emits start/result events" do
    script = """
    while IFS= read -r line; do
      printf '%s\n' 'helper boot log'
      printf '%s\n' '{malformed json'
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"child-1","seq":1}}'
      printf '%s\n' '{"jsonrpc":"2.0","id":"1","result":{"ok":true,"childID":"child-1","seq":1}}'
    done
    """

    {command, args} = Ourocode.Test.PortPrograms.shell_script(script)

    {:ok, transport} =
      Stdio.start_link(
        command: command,
        args: args,
        parent_call_id: "parent-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-1"},
        event_sink: self()
      )

    assert_receive {:ourocode_event, %{type: :transport_started, event_seq: 1}}

    assert {:ok, %{"ok" => true, "childID" => "child-1", "seq" => 1}} =
             Stdio.call_parent(transport, "tools/call", %{"name" => "synthetic"},
               timeout: @parent_call_timeout_ms
             )

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_started,
                      transport: :stdio,
                      parent_call_id: "parent-1",
                      runtime_source: "synthetic",
                      external_ids: %{"session_id" => "session-1"},
                      request_id: "1",
                      method: "tools/call",
                      event_seq: 2
                    }}

    assert_receive {:ourocode_event,
                    %{
                      type: :transport_decode_failed,
                      transport: :stdio,
                      parent_call_id: "parent-1",
                      error: {:malformed_stdout_line, _reason},
                      error_details: %{reason: _decode_reason},
                      raw_event: %{line: "{malformed json"},
                      event_seq: 3
                    }}

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_event,
                      transport: :stdio,
                      parent_call_id: "parent-1",
                      notification: %{
                        "jsonrpc" => "2.0",
                        "method" => "notifications/progress",
                        "params" => %{"childID" => "child-1", "seq" => 1}
                      },
                      event_seq: 4
                    } = child_event}

    pane_state =
      ChildSessionPanes.apply_event(
        %{working: [], completed: [], focused: nil, open: []},
        child_event
      )

    assert [
             %{
               id: "child-session:child-1",
               kind: :child_session,
               child_id: "child-1",
               parent_call_id: "parent-1",
               transport: :stdio,
               stream_cursor: %{event_seq: 4}
             }
           ] = pane_state.working

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_result,
                      transport: :stdio,
                      parent_call_id: "parent-1",
                      request_id: "1",
                      result: %{"ok" => true, "childID" => "child-1", "seq" => 1},
                      event_seq: 5
                    }}
  end

  test "normalizes malformed stdio stdout JSON into transport decode failure events" do
    script = """
    while IFS= read -r line; do
      printf '%s\n' 'helper startup log'
      printf '%s\n' '{malformed json'
      printf '%s\n' '{"jsonrpc":"2.0","id":"1","result":{"ok":true}}'
    done
    """

    {command, args} = Ourocode.Test.PortPrograms.shell_script(script)

    {:ok, transport} =
      Stdio.start_link(
        command: command,
        args: args,
        parent_call_id: "parent-malformed-stdio-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-malformed-stdio-1"},
        event_sink: self()
      )

    assert_receive {:ourocode_event,
                    %{type: :transport_started, parent_call_id: "parent-malformed-stdio-1"}}

    assert {:ok, %{"ok" => true}} =
             Stdio.call_parent(transport, "tools/call", %{"name" => "synthetic.malformed"},
               timeout: @parent_call_timeout_ms
             )

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_started,
                      transport: :stdio,
                      parent_call_id: "parent-malformed-stdio-1",
                      request_id: "1",
                      event_seq: 2
                    }}

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :transport_decode_failed,
                      transport: :stdio,
                      parent_call_id: "parent-malformed-stdio-1",
                      runtime_source: "synthetic",
                      external_ids: %{"session_id" => "session-malformed-stdio-1"},
                      error: {:malformed_stdout_line, _reason},
                      error_details: %{reason: _decode_reason},
                      raw_event: %{line: "{malformed json"},
                      event_seq: 3
                    }}

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_result,
                      transport: :stdio,
                      parent_call_id: "parent-malformed-stdio-1",
                      request_id: "1",
                      result: %{"ok" => true},
                      event_seq: 4
                    }}
  end

  test "attaches stdio raw event debugging metadata to outbound and inbound records" do
    script = """
    while IFS= read -r line; do
      printf '%s\n' '{malformed raw debug line'
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"child-raw-debug-stdio-1","seq":1}}'
      printf '%s\n' '{"jsonrpc":"2.0","id":"1","result":{"ok":true,"childID":"child-raw-debug-stdio-1","seq":2}}'
    done
    """

    {command, args} = Ourocode.Test.PortPrograms.shell_script(script)

    {:ok, transport} =
      Stdio.start_link(
        command: command,
        args: args,
        parent_call_id: "parent-raw-debug-stdio-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-raw-debug-stdio-1"},
        event_sink: self()
      )

    assert_receive {:ourocode_event,
                    %{type: :transport_started, parent_call_id: "parent-raw-debug-stdio-1"}}

    assert {:ok, %{"ok" => true, "childID" => "child-raw-debug-stdio-1", "seq" => 2}} =
             Stdio.call_parent(transport, "tools/call", %{"name" => "synthetic.raw_debug"},
               timeout: @parent_call_timeout_ms
             )

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_started,
                      raw_event: %{
                        "method" => "tools/call",
                        transport_type: :stdio,
                        transport: :stdio,
                        stream_direction: :outbound,
                        session_identifier: "session-raw-debug-stdio-1",
                        timestamp_ms: outbound_timestamp_ms,
                        raw_payload_ref: outbound_payload_ref,
                        process_identifier: %{port: outbound_port}
                      }
                    }}

    assert is_integer(outbound_timestamp_ms)
    assert is_binary(outbound_port)
    assert String.starts_with?(outbound_payload_ref, "sha256:")

    assert_receive {:ourocode_event,
                    %{
                      type: :transport_decode_failed,
                      raw_event: %{
                        line: "{malformed raw debug line",
                        transport_type: :stdio,
                        transport: :stdio,
                        stream_direction: :inbound,
                        session_identifier: "session-raw-debug-stdio-1",
                        timestamp_ms: decode_timestamp_ms,
                        raw_payload_ref: decode_payload_ref,
                        process_identifier: %{port: decode_port}
                      }
                    }}

    assert is_integer(decode_timestamp_ms)
    assert is_binary(decode_port)
    assert String.starts_with?(decode_payload_ref, "sha256:")

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_event,
                      raw_event: %{
                        "method" => "notifications/progress",
                        transport_type: :stdio,
                        transport: :stdio,
                        stream_direction: :inbound,
                        session_identifier: "session-raw-debug-stdio-1",
                        timestamp_ms: event_timestamp_ms,
                        raw_payload_ref: event_payload_ref,
                        process_identifier: %{port: event_port}
                      }
                    }}

    assert is_integer(event_timestamp_ms)
    assert is_binary(event_port)
    assert String.starts_with?(event_payload_ref, "sha256:")

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_result,
                      raw_event: %{
                        "id" => "1",
                        transport_type: :stdio,
                        transport: :stdio,
                        stream_direction: :inbound,
                        session_identifier: "session-raw-debug-stdio-1",
                        timestamp_ms: result_timestamp_ms,
                        raw_payload_ref: result_payload_ref,
                        process_identifier: %{port: result_port}
                      }
                    }}

    assert is_integer(result_timestamp_ms)
    assert is_binary(result_port)
    assert String.starts_with?(result_payload_ref, "sha256:")
  end

  test "continues processing valid stdout events surrounding malformed lines" do
    child_id = "child-malformed-recovery-stdio-1"

    journal_path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-stdio-malformed-recovery-#{System.unique_integer([:positive])}.jsonl"
      )

    on_exit(fn -> File.rm(journal_path) end)

    script = """
    while IFS= read -r line; do
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"#{child_id}","seq":1,"token":"before"}}'
      printf '%s\n' '{malformed before middle'
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"#{child_id}","seq":2,"token":"after-first-malformed"}}'
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"#{child_id}","seq":3,"token":"after-second-valid"}}'
      printf '%s\n' '{malformed before result'
      printf '%s\n' '{"jsonrpc":"2.0","id":"1","result":{"ok":true,"childID":"#{child_id}","seq":4}}'
    done
    """

    {command, args} = Ourocode.Test.PortPrograms.shell_script(script)

    {:ok, transport} =
      Stdio.start_link(
        command: command,
        args: args,
        parent_call_id: "parent-malformed-recovery-stdio-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-malformed-recovery-stdio-1"},
        event_sink: self(),
        journal_path: journal_path
      )

    assert_receive {:ourocode_event, %{type: :transport_started, event_seq: 1} = started_event}

    assert {:ok, %{"ok" => true, "childID" => ^child_id, "seq" => 4}} =
             Stdio.call_parent(
               transport,
               "tools/call",
               %{"name" => "synthetic.malformed_recovery"},
               timeout: @parent_call_timeout_ms
             )

    received_events =
      Enum.map(2..8, fn expected_seq ->
        assert_receive {:ourocode_event, %{event_seq: ^expected_seq} = event}, 1_000
        event
      end)

    assert Enum.map(received_events, & &1.type) == [
             :parent_call_started,
             :parent_call_event,
             :transport_decode_failed,
             :parent_call_event,
             :parent_call_event,
             :transport_decode_failed,
             :parent_call_result
           ]

    stream_events = Enum.filter(received_events, &(&1.type == :parent_call_event))

    assert Enum.map(stream_events, &get_in(&1, [:payload, "seq"])) == [1, 2, 3]

    assert Enum.map(stream_events, &get_in(&1, [:payload, "token"])) == [
             "before",
             "after-first-malformed",
             "after-second-valid"
           ]

    all_events = [started_event | received_events]

    assert :ok = Journal.verify_no_event_seq_gaps(all_events)

    assert {:ok, journal_entries} = Journal.read_ordered(journal_path)
    assert Enum.map(journal_entries, & &1.event_seq) == Enum.to_list(1..8)
    assert Enum.map(journal_entries, & &1.type) == Enum.map(all_events, & &1.type)
  end

  test "normalizes stdio JSON-RPC server requests as lifecycle events instead of responses" do
    script = """
    while IFS= read -r line; do
      printf '%s\n' '{"jsonrpc":"2.0","id":"server-request-1","method":"sampling/createMessage","params":{"childID":"child-server-request-1","seq":1,"token":"question"}}'
      printf '%s\n' '{"jsonrpc":"2.0","id":"1","result":{"ok":true,"childID":"child-server-request-1","seq":2}}'
    done
    """

    {command, args} = Ourocode.Test.PortPrograms.shell_script(script)

    {:ok, transport} =
      Stdio.start_link(
        command: command,
        args: args,
        parent_call_id: "parent-server-request-stdio-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-server-request-stdio-1"},
        event_sink: self()
      )

    assert_receive {:ourocode_event,
                    %{type: :transport_started, parent_call_id: "parent-server-request-stdio-1"}}

    assert {:ok, %{"ok" => true, "childID" => "child-server-request-1", "seq" => 2}} =
             Stdio.call_parent(transport, "tools/call", %{"name" => "synthetic.server_request"},
               timeout: @parent_call_timeout_ms
             )

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_started,
                      transport: :stdio,
                      parent_call_id: "parent-server-request-stdio-1",
                      request_id: "1",
                      event_seq: 2
                    }}

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_event,
                      transport: :stdio,
                      parent_call_id: "parent-server-request-stdio-1",
                      request_id: "server-request-1",
                      method: "sampling/createMessage",
                      params: %{
                        "childID" => "child-server-request-1",
                        "seq" => 1,
                        "token" => "question"
                      },
                      payload: %{
                        "childID" => "child-server-request-1",
                        "seq" => 1,
                        "token" => "question"
                      },
                      notification: %{
                        "id" => "server-request-1",
                        "method" => "sampling/createMessage"
                      },
                      event_seq: 3
                    }}

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_result,
                      transport: :stdio,
                      parent_call_id: "parent-server-request-stdio-1",
                      request_id: "1",
                      result: %{"ok" => true, "childID" => "child-server-request-1", "seq" => 2},
                      event_seq: 4
                    }}
  end

  test "ingests synthetic stdio MCP events seq=1..N without dropping normalized sequences" do
    event_count = 12
    child_id = "child-seq-stdio-1"
    result_seq = event_count + 1
    last_stream_event_seq = event_count + 2
    result_event_seq = event_count + 3

    stream_lines =
      Enum.map_join(1..event_count, "\n", fn seq ->
        token = "token-#{seq}"

        json =
          ~s({"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"#{child_id}","seq":#{seq},"token":"#{token}"}})

        ~s(printf '%s\\n' '#{json}')
      end)

    result_json =
      ~s({"jsonrpc":"2.0","id":"1","result":{"ok":true,"childID":"#{child_id}","seq":#{result_seq}}})

    script = """
    while IFS= read -r line; do
      #{stream_lines}
      printf '%s\n' '#{result_json}'
    done
    """

    {command, args} = Ourocode.Test.PortPrograms.shell_script(script)

    {:ok, transport} =
      Stdio.start_link(
        command: command,
        args: args,
        parent_call_id: "parent-seq-stdio-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-seq-stdio-1"},
        event_sink: self()
      )

    assert_receive {:ourocode_event,
                    %{
                      type: :transport_started,
                      parent_call_id: "parent-seq-stdio-1",
                      event_seq: 1
                    }}

    assert {:ok, %{"ok" => true, "childID" => ^child_id, "seq" => ^result_seq}} =
             Stdio.call_parent(transport, "tools/call", %{"name" => "synthetic.seq"},
               timeout: @parent_call_timeout_ms
             )

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_started,
                      transport: :stdio,
                      parent_call_id: "parent-seq-stdio-1",
                      runtime_source: "synthetic",
                      request_id: "1",
                      event_seq: 2
                    } = started_event}

    stream_events =
      Enum.map(1..event_count, fn seq ->
        assert_receive {:ourocode_event,
                        %{
                          type: :parent_call_event,
                          transport: :stdio,
                          parent_call_id: "parent-seq-stdio-1",
                          payload: %{"childID" => ^child_id, "seq" => ^seq, "token" => token},
                          notification: %{
                            "method" => "notifications/progress",
                            "params" => %{"childID" => ^child_id, "seq" => ^seq}
                          },
                          event_seq: event_seq
                        } = event}

        assert token == "token-#{seq}"
        assert event_seq == seq + 2
        event
      end)

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_result,
                      transport: :stdio,
                      parent_call_id: "parent-seq-stdio-1",
                      payload: %{"ok" => true, "childID" => ^child_id, "seq" => ^result_seq},
                      event_seq: ^result_event_seq
                    }}

    assert Enum.map(stream_events, &get_in(&1, [:payload, "seq"])) == Enum.to_list(1..event_count)
    assert Enum.map(stream_events, & &1.event_seq) == Enum.to_list(3..(event_count + 2))

    child_state =
      Enum.reduce(stream_events, %{working: [], completed: [], focused: nil, open: []}, fn
        event, state ->
          ChildSessionPanes.apply_event(state, event)
      end)

    assert [
             %{
               child_id: ^child_id,
               parent_call_id: "parent-seq-stdio-1",
               transport: :stdio,
               stream_cursor: %{event_seq: ^last_stream_event_seq},
               pane_state: %{stream_entries: stream_entries}
             }
           ] = child_state.working

    assert Enum.map(stream_entries, & &1.runtime_seq) == Enum.to_list(1..event_count)
    assert Enum.map(stream_entries, & &1.token) == Enum.map(1..event_count, &"token-#{&1}")

    rendered_children = ChildSessionPanes.render(child_state)

    assert [
             %{
               child_id: ^child_id,
               transport: "stdio",
               stream_event_count: ^event_count,
               pane_state: %{stream_entries: rendered_stream_entries}
             }
           ] = rendered_children.working

    assert Enum.map(rendered_stream_entries, & &1.runtime_seq) == Enum.to_list(1..event_count)

    parent_state =
      [started_event | stream_events]
      |> Enum.reduce(%{working: [], completed: [], focused: nil, open: []}, fn event, state ->
        ParentMcpPane.apply_event(state, event)
      end)

    frame = Layout.render_runtime_frame(parent_state, child_state)

    rendered_runtime_seqs =
      ~r/(?:stream=\[|\|)(\d+):token=token-\d+/
      |> Regex.scan(frame, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.to_integer/1)

    assert rendered_runtime_seqs == Enum.to_list(1..event_count)

    tree = UITree.from_panes(parent_state, child_state)

    assert [
             %{
               children: [
                 %{
                   child_id: ^child_id,
                   transport: :stdio,
                   stream_events: rendered_stream_events
                 }
               ]
             }
           ] = tree.roots

    assert Enum.map(rendered_stream_events, & &1.runtime_seq) == Enum.to_list(1..event_count)

    assert Enum.map(rendered_stream_events, & &1.token) ==
             Enum.map(1..event_count, &"token-#{&1}")
  end

  test "preserves valid stdout MCP event order while normalizing malformed stdout lines" do
    child_id = "child-valid-stdout-order-stdio-1"

    script = """
    while IFS= read -r line; do
      printf '%s\n' 'helper startup log before protocol'
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"#{child_id}","seq":1,"token":"first"}}'
      printf '%s\n' '{not valid json'
      printf '%s\n' '["valid json but not a JSON-RPC object"]'
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"#{child_id}","seq":2,"token":"second"}}'
      printf '%s\n' ''
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"#{child_id}","seq":3,"token":"third"}}'
      printf '%s\n' 'helper shutdown log between protocol and result'
      printf '%s\n' '{"jsonrpc":"2.0","id":"1","result":{"ok":true,"childID":"#{child_id}","seq":4}}'
    done
    """

    {command, args} = Ourocode.Test.PortPrograms.shell_script(script)

    {:ok, transport} =
      Stdio.start_link(
        command: command,
        args: args,
        parent_call_id: "parent-valid-stdout-order-stdio-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-valid-stdout-order-stdio-1"},
        event_sink: self()
      )

    assert_receive {:ourocode_event,
                    %{
                      type: :transport_started,
                      parent_call_id: "parent-valid-stdout-order-stdio-1",
                      event_seq: 1
                    }}

    assert {:ok, %{"ok" => true, "childID" => ^child_id, "seq" => 4}} =
             Stdio.call_parent(transport, "tools/call", %{"name" => "synthetic.valid_order"},
               timeout: @parent_call_timeout_ms
             )

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_started,
                      parent_call_id: "parent-valid-stdout-order-stdio-1",
                      request_id: "1",
                      event_seq: 2
                    }}

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_event,
                      transport: :stdio,
                      parent_call_id: "parent-valid-stdout-order-stdio-1",
                      payload: %{"childID" => ^child_id, "seq" => 1, "token" => "first"},
                      event_seq: 3
                    } = first_event}

    assert_receive {:ourocode_event,
                    %{
                      type: :transport_decode_failed,
                      transport: :stdio,
                      parent_call_id: "parent-valid-stdout-order-stdio-1",
                      error: {:malformed_stdout_line, _reason},
                      raw_event: %{line: "{not valid json"},
                      event_seq: 4
                    }}

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_event,
                      transport: :stdio,
                      parent_call_id: "parent-valid-stdout-order-stdio-1",
                      payload: %{"childID" => ^child_id, "seq" => 2, "token" => "second"},
                      event_seq: 5
                    } = second_event}

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_event,
                      transport: :stdio,
                      parent_call_id: "parent-valid-stdout-order-stdio-1",
                      payload: %{"childID" => ^child_id, "seq" => 3, "token" => "third"},
                      event_seq: 6
                    } = third_event}

    ordered_stream_events = [first_event, second_event, third_event]

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_result,
                      parent_call_id: "parent-valid-stdout-order-stdio-1",
                      request_id: "1",
                      result: %{"ok" => true, "childID" => ^child_id, "seq" => 4},
                      event_seq: 7
                    }}

    assert Enum.map(ordered_stream_events, &get_in(&1, [:payload, "seq"])) == [1, 2, 3]

    assert Enum.map(ordered_stream_events, &get_in(&1, [:payload, "token"])) ==
             ["first", "second", "third"]

    refute_receive {:ourocode_event, %{type: :transport_decode_failed}}, 50
  end

  test "persists normalized stdio MCP server events seq=1..N and reads them back without gaps" do
    event_count = 8
    child_id = "child-journal-stdio-1"

    journal_path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-stdio-journal-#{System.unique_integer([:positive])}.jsonl"
      )

    on_exit(fn -> File.rm(journal_path) end)

    stream_lines =
      Enum.map_join(1..event_count, "\n", fn seq ->
        token = "journal-token-#{seq}"

        json =
          ~s({"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"#{child_id}","seq":#{seq},"token":"#{token}"}})

        ~s(printf '%s\\n' '#{json}')
      end)

    result_seq = event_count + 1

    result_json =
      ~s({"jsonrpc":"2.0","id":"1","result":{"ok":true,"childID":"#{child_id}","seq":#{result_seq}}})

    script = """
    while IFS= read -r line; do
      #{stream_lines}
      printf '%s\n' '#{result_json}'
    done
    """

    {command, args} = Ourocode.Test.PortPrograms.shell_script(script)

    {:ok, transport} =
      Stdio.start_link(
        command: command,
        args: args,
        parent_call_id: "parent-journal-stdio-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-journal-stdio-1"},
        event_sink: self(),
        journal_path: journal_path
      )

    assert_receive {:ourocode_event, %{type: :transport_started, event_seq: 1}}

    assert {:ok, %{"ok" => true, "childID" => ^child_id, "seq" => ^result_seq}} =
             Stdio.call_parent(transport, "tools/call", %{"name" => "synthetic.journal"},
               timeout: @parent_call_timeout_ms
             )

    received_events =
      Enum.map(2..(event_count + 3), fn expected_seq ->
        assert_receive {:ourocode_event, %{event_seq: ^expected_seq} = event}
        event
      end)

    assert :ok = Journal.verify_no_event_seq_gaps([%{event_seq: 1} | received_events])

    assert {:ok, journal_entries} = Journal.read_ordered(journal_path)
    assert Enum.map(journal_entries, & &1.event_seq) == Enum.to_list(1..(event_count + 3))

    assert Enum.map(journal_entries, & &1.type) ==
             [
               :transport_started,
               :parent_call_started
             ] ++ List.duplicate(:parent_call_event, event_count) ++ [:parent_call_result]

    stream_entries =
      Enum.filter(journal_entries, fn entry ->
        entry.type == :parent_call_event and get_in(entry, [:payload, "childID"]) == child_id
      end)

    assert Enum.map(stream_entries, &get_in(&1, [:payload, "seq"])) ==
             Enum.to_list(1..event_count)

    assert Enum.map(stream_entries, &get_in(&1, [:payload, "token"])) ==
             Enum.map(1..event_count, &"journal-token-#{&1}")

    assert [
             %{
               type: :parent_call_result,
               transport: :stdio,
               parent_call_id: "parent-journal-stdio-1",
               payload: %{"ok" => true, "childID" => ^child_id, "seq" => ^result_seq}
             }
           ] = Enum.filter(journal_entries, &(&1.type == :parent_call_result))
  end

  test "journal replay reconstructs normalized stdio events with raw metadata" do
    child_id = "child-canonical-journal-stdio-1"

    journal_path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-stdio-canonical-journal-#{System.unique_integer([:positive])}.jsonl"
      )

    on_exit(fn -> File.rm(journal_path) end)

    script = """
    while IFS= read -r line; do
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"#{child_id}","seq":1,"token":"canonical-token"}}'
      printf '%s\n' '{malformed raw stdio line that must not be journaled'
      printf '%s\n' '{"jsonrpc":"2.0","id":"1","result":{"ok":true,"childID":"#{child_id}","seq":2}}'
    done
    """

    {command, args} = Ourocode.Test.PortPrograms.shell_script(script)

    {:ok, transport} =
      Stdio.start_link(
        command: command,
        args: args,
        parent_call_id: "parent-canonical-journal-stdio-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-canonical-journal-stdio-1"},
        event_sink: self(),
        journal_path: journal_path
      )

    assert_receive {:ourocode_event, %{type: :transport_started, event_seq: 1}}

    assert {:ok, %{"ok" => true, "childID" => ^child_id, "seq" => 2}} =
             Stdio.call_parent(
               transport,
               "tools/call",
               %{"name" => "synthetic.canonical_journal"},
               timeout: @parent_call_timeout_ms
             )

    live_events =
      Enum.map(2..5, fn expected_seq ->
        assert_receive {:ourocode_event, %{event_seq: ^expected_seq} = event}
        event
      end)

    assert Enum.map(live_events, & &1.type) == [
             :parent_call_started,
             :parent_call_event,
             :transport_decode_failed,
             :parent_call_result
           ]

    assert Enum.any?(
             live_events,
             &match?(
               %{raw_event: %{line: "{malformed raw stdio line that must not be journaled"}},
               &1
             )
           )

    assert {:ok, journal_entries} = Journal.read_ordered(journal_path)

    assert Enum.map(journal_entries, & &1.type) == [
             :transport_started,
             :parent_call_started,
             :parent_call_event,
             :transport_decode_failed,
             :parent_call_result
           ]

    assert Enum.count(journal_entries, &Map.has_key?(&1, :raw_event)) == 4

    assert %{
             type: :parent_call_event,
             transport: :stdio,
             parent_call_id: "parent-canonical-journal-stdio-1",
             payload: %{"childID" => ^child_id, "seq" => 1, "token" => "canonical-token"},
             notification: %{
               "method" => "notifications/progress",
               "params" => %{"childID" => ^child_id, "seq" => 1, "token" => "canonical-token"}
             },
             raw_event: %{
               "method" => "notifications/progress",
               transport: :stdio,
               transport_type: :stdio,
               stream_direction: :inbound,
               session_identifier: "session-canonical-journal-stdio-1",
               raw_payload_ref: event_payload_ref
             }
           } = Enum.find(journal_entries, &(&1.type == :parent_call_event))

    assert String.starts_with?(event_payload_ref, "sha256:")

    assert %{
             type: :transport_decode_failed,
             error: ["malformed_stdout_line", "expected_object_key"],
             error_details: %{"reason" => "expected_object_key"},
             raw_event: %{
               line: "{malformed raw stdio line that must not be journaled",
               transport: :stdio,
               transport_type: :stdio,
               stream_direction: :inbound,
               raw_payload_ref: decode_payload_ref
             }
           } = Enum.find(journal_entries, &(&1.type == :transport_decode_failed))

    assert String.starts_with?(decode_payload_ref, "sha256:")

    assert {:ok, journal_jsonl} = File.read(journal_path)
    assert journal_jsonl =~ "raw_event"
    assert journal_jsonl =~ "jsonrpc"
    assert journal_jsonl =~ "{malformed raw stdio line that must not be journaled"
  end

  test "renders stdio parent MCP call as the root UI pane with identity and status metadata" do
    script = """
    while IFS= read -r line; do
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"child-root-1","seq":1,"token":"first"}}'
      printf '%s\n' '{"jsonrpc":"2.0","id":"1","result":{"ok":true,"childID":"child-root-1","seq":1}}'
    done
    """

    {command, args} = Ourocode.Test.PortPrograms.shell_script(script)

    {:ok, transport} =
      Stdio.start_link(
        command: command,
        args: args,
        parent_call_id: "parent-root-stdio-1",
        runtime_source: "synthetic",
        external_ids: %{
          "session_id" => "session-root-1",
          "input" => %{"callID" => "input-call-root-1"}
        },
        event_sink: self()
      )

    assert_receive {:ourocode_event, %{type: :transport_started}}

    assert {:ok, %{"ok" => true, "childID" => "child-root-1", "seq" => 1}} =
             Stdio.call_parent(transport, "tools/call", %{"name" => "synthetic.root"},
               timeout: @parent_call_timeout_ms
             )

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_started,
                      transport: :stdio,
                      parent_call_id: "parent-root-stdio-1",
                      runtime_source: "synthetic",
                      external_ids: %{
                        "session_id" => "session-root-1",
                        "input" => %{"callID" => "input-call-root-1"}
                      },
                      request_id: "1",
                      method: "tools/call",
                      event_seq: 2
                    } = started_event}

    state =
      ParentMcpPane.apply_event(
        %{working: [], completed: [], focused: nil, open: []},
        started_event
      )

    assert %{
             id: :parent_mcp_calls,
             title: "Parent MCP",
             empty?: false,
             focused: "parent-mcp:parent-root-stdio-1",
             open: ["parent-mcp:parent-root-stdio-1"],
             working: [
               %{
                 id: "parent-mcp:parent-root-stdio-1",
                 kind: :parent_mcp_call,
                 title: "Parent MCP",
                 status: "starting",
                 lifecycle: "parent_call_started",
                 parent_call_id: "parent-root-stdio-1",
                 runtime_source: "synthetic",
                 transport: "stdio",
                 request_id: "1",
                 method: "tools/call",
                 external_ids: %{
                   "session_id" => "session-root-1",
                   "input" => %{"callID" => "input-call-root-1"}
                 },
                 stream_cursor: %{
                   transport: :stdio,
                   parent_call_id: "parent-root-stdio-1",
                   event_seq: 2
                 },
                 event_count: 1,
                 notification_count: 0,
                 line:
                   "[starting] parent=parent-root-stdio-1 lifecycle=parent_call_started runtime=synthetic transport=stdio request=1 method=tools/call seq=2 events=1 notifications=0"
               }
             ],
             completed: []
           } = ParentMcpPane.render(state)

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_event,
                      transport: :stdio,
                      parent_call_id: "parent-root-stdio-1",
                      notification: %{
                        "params" => %{
                          "childID" => "child-root-1",
                          "seq" => 1,
                          "token" => "first"
                        }
                      },
                      event_seq: 3
                    } = streaming_event}

    assert %{
             working: [
               %{
                 status: "streaming",
                 parent_call_id: "parent-root-stdio-1",
                 stream_cursor: %{event_seq: 3},
                 event_count: 2,
                 notification_count: 1
               }
             ]
           } =
             state
             |> ParentMcpPane.apply_event(streaming_event)
             |> ParentMcpPane.render()

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_result,
                      transport: :stdio,
                      parent_call_id: "parent-root-stdio-1",
                      request_id: "1",
                      result: %{"ok" => true, "childID" => "child-root-1", "seq" => 1},
                      event_seq: 4
                    }}
  end

  test "preserves OpenCode parent call input sessionID and callID in lifecycle identity" do
    script = """
    while IFS= read -r line; do
      printf '%s\n' '{"jsonrpc":"2.0","id":"1","result":{"ok":true}}'
    done
    """

    {command, args} = Ourocode.Test.PortPrograms.shell_script(script)

    {:ok, transport} =
      Stdio.start_link(
        command: command,
        args: args,
        parent_call_id: "parent-opencode-input-1",
        runtime_source: "opencode",
        external_ids: %{},
        event_sink: self()
      )

    assert_receive {:ourocode_event, %{type: :transport_started}}

    params = %{
      "input" => %{
        "sessionID" => " opencode-session-stdio-1 ",
        "callID" => " opencode-call-stdio-1 ",
        "prompt" => "describe a task for a new session"
      }
    }

    assert {:ok, %{"ok" => true}} =
             Stdio.call_parent(transport, "agent/session/create", params,
               timeout: @parent_call_timeout_ms
             )

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_started,
                      parent_call_id: "parent-opencode-input-1",
                      runtime_source: "opencode",
                      method: "agent/session/create",
                      external_ids: %{
                        session_id: "opencode-session-stdio-1",
                        input_session_id: "opencode-session-stdio-1",
                        input_call_id: "opencode-call-stdio-1",
                        input: %{
                          "sessionID" => "opencode-session-stdio-1",
                          "callID" => "opencode-call-stdio-1"
                        }
                      }
                    }}

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_result,
                      parent_call_id: "parent-opencode-input-1",
                      external_ids: %{
                        session_id: "opencode-session-stdio-1",
                        input_session_id: "opencode-session-stdio-1",
                        input_call_id: "opencode-call-stdio-1",
                        input: %{
                          "sessionID" => "opencode-session-stdio-1",
                          "callID" => "opencode-call-stdio-1"
                        }
                      }
                    }}
  end

  test "appends stdio streaming token entries under the correct child panes in order" do
    script = """
    while IFS= read -r line; do
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"child-stream-a","seq":1,"token":"a-1"}}'
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"child-stream-b","seq":1,"token":"b-1"}}'
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"child-stream-a","seq":2,"token":"a-2"}}'
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"child-stream-a","seq":3,"token":"a-3"}}'
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"child-stream-b","seq":2,"token":"b-2"}}'
      printf '%s\n' '{"jsonrpc":"2.0","id":"1","result":{"ok":true}}'
    done
    """

    {command, args} = Ourocode.Test.PortPrograms.shell_script(script)

    {:ok, transport} =
      Stdio.start_link(
        command: command,
        args: args,
        parent_call_id: "parent-stream-stdio-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-stream-stdio-1"},
        event_sink: self()
      )

    assert_receive {:ourocode_event,
                    %{type: :transport_started, parent_call_id: "parent-stream-stdio-1"}}

    assert {:ok, %{"ok" => true}} =
             Stdio.call_parent(transport, "tools/call", %{"name" => "synthetic.stream"},
               timeout: @parent_call_timeout_ms
             )

    assert_receive {:ourocode_event,
                    %{type: :parent_call_started, parent_call_id: "parent-stream-stdio-1"} =
                      started}

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_event,
                      parent_call_id: "parent-stream-stdio-1",
                      notification: %{"params" => %{"childID" => "child-stream-a", "seq" => 1}}
                    } = a1}

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_event,
                      parent_call_id: "parent-stream-stdio-1",
                      notification: %{"params" => %{"childID" => "child-stream-b", "seq" => 1}}
                    } = b1}

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_event,
                      parent_call_id: "parent-stream-stdio-1",
                      notification: %{"params" => %{"childID" => "child-stream-a", "seq" => 2}}
                    } = a2}

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_event,
                      parent_call_id: "parent-stream-stdio-1",
                      notification: %{"params" => %{"childID" => "child-stream-a", "seq" => 3}}
                    } = a3}

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_event,
                      parent_call_id: "parent-stream-stdio-1",
                      notification: %{"params" => %{"childID" => "child-stream-b", "seq" => 2}}
                    } = b2}

    assert_receive {:ourocode_event,
                    %{type: :parent_call_result, parent_call_id: "parent-stream-stdio-1"} =
                      result}

    {parent_state, child_state} =
      Enum.reduce(
        [started, a1, b1, a2, a3, b2, result],
        {
          %{working: [], completed: [], focused: nil, open: []},
          %{working: [], completed: [], focused: nil, open: []}
        },
        fn event, {parent_state, child_state} ->
          {
            ParentMcpPane.apply_event(parent_state, event),
            ChildSessionPanes.apply_event(child_state, event)
          }
        end
      )

    hierarchy = Layout.parent_child_hierarchy(parent_state, child_state)

    assert [%{parent_call_id: "parent-stream-stdio-1", children: children}] = hierarchy.roots
    assert hierarchy.orphan_children == []

    children_by_id = Map.new(children, &{&1.child_id, &1})
    assert Map.keys(children_by_id) |> Enum.sort() == ["child-stream-a", "child-stream-b"]

    assert %{
             pane_state: %{
               stream_entries: [
                 %{runtime_seq: 1, token: "a-1"},
                 %{runtime_seq: 2, token: "a-2"},
                 %{runtime_seq: 3, token: "a-3"}
               ]
             },
             stream_cursor: %{event_seq: 6}
           } = children_by_id["child-stream-a"]

    assert %{
             pane_state: %{
               stream_entries: [
                 %{runtime_seq: 1, token: "b-1"},
                 %{runtime_seq: 2, token: "b-2"}
               ]
             },
             stream_cursor: %{event_seq: 7}
           } = children_by_id["child-stream-b"]
  end

  test "delivers the first stdio token to the child pane within five seconds of childID creation" do
    script = """
    while IFS= read -r line; do
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"child-stdio-timing-1","phase":"created"}}'
      sleep 1
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"child-stdio-timing-1","seq":1,"token":"first-token"}}'
      printf '%s\n' '{"jsonrpc":"2.0","id":"1","result":{"ok":true,"childID":"child-stdio-timing-1","seq":1}}'
    done
    """

    {command, args} = Ourocode.Test.PortPrograms.shell_script(script)

    {:ok, transport} =
      Stdio.start_link(
        command: command,
        args: args,
        parent_call_id: "parent-stdio-timing-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-stdio-timing-1"},
        event_sink: self()
      )

    assert_receive {:ourocode_event,
                    %{type: :transport_started, parent_call_id: "parent-stdio-timing-1"}},
                   15_000

    call_task =
      Task.async(fn ->
        Stdio.call_parent(transport, "tools/call", %{"name" => "synthetic.timing"},
          timeout: 15_000
        )
      end)

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_started,
                      parent_call_id: "parent-stdio-timing-1",
                      request_id: "1"
                    }},
                   15_000

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_event,
                      transport: :stdio,
                      parent_call_id: "parent-stdio-timing-1",
                      notification: %{
                        "params" => %{
                          "childID" => "child-stdio-timing-1",
                          "phase" => "created"
                        }
                      }
                    } = child_created_event},
                   15_000

    child_created_received_at = System.monotonic_time(:millisecond)

    child_state =
      ChildSessionPanes.apply_event(
        %{working: [], completed: [], focused: nil, open: []},
        child_created_event
      )

    assert [
             %{
               id: "child-session:child-stdio-timing-1",
               child_id: "child-stdio-timing-1",
               parent_call_id: "parent-stdio-timing-1",
               stream_cursor: %{event_seq: child_created_seq},
               pane_state: %{stream_entries: []}
             }
           ] = child_state.working

    assert child_created_seq == child_created_event.event_seq

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_event,
                      transport: :stdio,
                      parent_call_id: "parent-stdio-timing-1",
                      notification: %{
                        "params" => %{
                          "childID" => "child-stdio-timing-1",
                          "seq" => 1,
                          "token" => "first-token"
                        }
                      }
                    } = first_token_event},
                   5_000

    first_token_received_at = System.monotonic_time(:millisecond)
    assert first_token_received_at - child_created_received_at <= 5_000
    assert first_token_event.occurred_at_ms - child_created_event.occurred_at_ms <= 5_000

    child_state = ChildSessionPanes.apply_event(child_state, first_token_event)

    assert [
             %{
               id: "child-session:child-stdio-timing-1",
               child_id: "child-stdio-timing-1",
               parent_call_id: "parent-stdio-timing-1",
               stream_cursor: %{event_seq: first_token_seq},
               pane_state: %{
                 stream_entries: [
                   %{
                     event_seq: first_token_seq,
                     runtime_seq: 1,
                     token: "first-token",
                     payload: %{
                       "childID" => "child-stdio-timing-1",
                       "seq" => 1,
                       "token" => "first-token"
                     }
                   }
                 ]
               }
             }
           ] = child_state.working

    assert first_token_seq == first_token_event.event_seq

    assert {:ok, %{"ok" => true, "childID" => "child-stdio-timing-1", "seq" => 1}} =
             Task.await(call_task, 2_000)

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_result,
                      parent_call_id: "parent-stdio-timing-1",
                      result: %{"ok" => true, "childID" => "child-stdio-timing-1", "seq" => 1}
                    }}
  end
end
