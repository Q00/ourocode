defmodule Ourocode.MCP.Transport.SSETest do
  use ExUnit.Case, async: false

  alias Ourocode.Json
  alias Ourocode.Dashboard.{ChildSessionPanes, Layout, ParentMcpPane, UITree}
  alias Ourocode.Journal
  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.SSE

  test "establishes and maintains an SSE MCP connection and emits streamed events" do
    {:ok, server} =
      start_fake_sse_server([
        {:send,
         [
           "HTTP/1.1 200 OK\r\n",
           "content-type: text/event-stream\r\n",
           "cache-control: no-cache\r\n",
           "connection: keep-alive\r\n",
           "\r\n"
         ]},
        {:send,
         sse_frame(%{
           "jsonrpc" => "2.0",
           "method" => "notifications/progress",
           "params" => %{"childID" => "child-1", "seq" => 1}
         })},
        {:sleep, 25},
        {:send,
         sse_frame(%{
           "jsonrpc" => "2.0",
           "id" => "call-1",
           "result" => %{"childID" => "child-1", "seq" => 2, "ok" => true}
         })},
        {:sleep, 100}
      ])

    assert {:ok, _transport} =
             SSE.start_link(
               url: "http://127.0.0.1:#{server.port}/mcp/events?session=session-1",
               parent_call_id: "parent-sse-1",
               runtime_source: "synthetic",
               external_ids: %{"session_id" => "session-1", "call_id" => "call-1"},
               connection_identifier: "sse-connection-test-1",
               event_sink: self(),
               timeout: 1_000
             )

    assert_receive {:fake_sse_request, request}, 500
    assert request =~ "GET /mcp/events?session=session-1 HTTP/1.1"
    assert request =~ "accept: text/event-stream"

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :transport_connected,
                      transport: :sse,
                      parent_call_id: "parent-sse-1",
                      runtime_source: "synthetic",
                      external_ids: %{"session_id" => "session-1", "call_id" => "call-1"},
                      event_seq: 1,
                      status: 200
                    }},
                   500

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_event,
                      transport: :sse,
                      parent_call_id: "parent-sse-1",
                      notification: %{
                        "jsonrpc" => "2.0",
                        "method" => "notifications/progress",
                        "params" => %{"childID" => "child-1", "seq" => 1}
                      },
                      raw_event: %{
                        transport_type: :sse,
                        endpoint_url: endpoint_url,
                        connection_identifier: "sse-connection-test-1",
                        session_identifier: "session-1",
                        timestamp_ms: timestamp_ms
                      },
                      event_seq: 2,
                      status: 200
                    }},
                   500

    assert endpoint_url =~ "/mcp/events?session=session-1"
    assert is_integer(timestamp_ms)

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_result,
                      transport: :sse,
                      parent_call_id: "parent-sse-1",
                      call_id: "call-1",
                      request_id: "call-1",
                      payload: %{"childID" => "child-1", "seq" => 2, "ok" => true},
                      result: %{"childID" => "child-1", "seq" => 2, "ok" => true},
                      raw_event: %{
                        transport_type: :sse,
                        endpoint_url: result_endpoint_url,
                        connection_identifier: "sse-connection-test-1",
                        session_identifier: "session-1",
                        timestamp_ms: result_timestamp_ms
                      },
                      event_seq: 3,
                      status: 200
                    }},
                   500

    assert result_endpoint_url =~ "/mcp/events?session=session-1"
    assert is_integer(result_timestamp_ms)
  end

  test "dispatches a parent MCP call request over an established SSE transport" do
    {:ok, server} = start_fake_sse_dispatch_server()

    assert {:ok, transport} =
             SSE.start_link(
               url: "http://127.0.0.1:#{server.port}/mcp/events?session=session-1",
               dispatch_url: "http://127.0.0.1:#{server.port}/mcp/messages?session=session-1",
               parent_call_id: "parent-sse-dispatch",
               runtime_source: "synthetic",
               external_ids: %{"session_id" => "session-1"},
               event_sink: self(),
               timeout: 1_000
             )

    assert_receive {:fake_sse_request, request}, 500
    assert request =~ "GET /mcp/events?session=session-1 HTTP/1.1"

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :transport_connected,
                      transport: :sse,
                      parent_call_id: "parent-sse-dispatch",
                      event_seq: 1,
                      status: 200
                    }},
                   500

    assert {:ok, %{request_id: "call-1", status: 202, response: %{"accepted" => true}}} =
             SSE.call_parent(
               transport,
               "tools/call",
               %{"name" => "ooo.run", "arguments" => %{"task" => "ping"}},
               request_id: "call-1",
               timeout: 1_000
             )

    assert_receive {:fake_sse_dispatch_request, dispatch_request}, 500
    assert dispatch_request =~ "POST /mcp/messages?session=session-1 HTTP/1.1"
    assert dispatch_request =~ "\"id\":\"call-1\""
    assert dispatch_request =~ "\"method\":\"tools/call\""
    assert dispatch_request =~ "\"task\":\"ping\""

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_started,
                      transport: :sse,
                      parent_call_id: "parent-sse-dispatch",
                      runtime_source: "synthetic",
                      external_ids: %{"session_id" => "session-1"},
                      request_id: "call-1",
                      method: "tools/call",
                      params: %{"name" => "ooo.run", "arguments" => %{"task" => "ping"}},
                      event_seq: 2,
                      status: 202
                    }},
                   500

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_result,
                      transport: :sse,
                      parent_call_id: "parent-sse-dispatch",
                      call_id: "call-1",
                      request_id: "call-1",
                      payload: %{"childID" => "child-1", "seq" => 1, "ok" => true},
                      result: %{"childID" => "child-1", "seq" => 1, "ok" => true},
                      event_seq: 3,
                      status: 200
                    }},
                   500
  end

  test "renders SSE streaming token entries under the correct child session node" do
    {:ok, server} =
      start_fake_sse_server([
        {:send,
         [
           "HTTP/1.1 200 OK\r\n",
           "content-type: text/event-stream\r\n",
           "cache-control: no-cache\r\n",
           "connection: keep-alive\r\n",
           "\r\n"
         ]},
        {:send,
         sse_frame(%{
           "jsonrpc" => "2.0",
           "method" => "notifications/progress",
           "params" => %{"childID" => "child-sse-stream-1", "seq" => 1, "token" => "alpha"}
         })},
        {:sleep, 25},
        {:send,
         sse_frame(%{
           "jsonrpc" => "2.0",
           "method" => "notifications/progress",
           "params" => %{"childID" => "child-sse-stream-2", "seq" => 1, "token" => "side"}
         })},
        {:sleep, 25},
        {:send,
         sse_frame(%{
           "jsonrpc" => "2.0",
           "method" => "notifications/progress",
           "params" => %{"childID" => "child-sse-stream-1", "seq" => 2, "token" => "beta"}
         })},
        {:sleep, 25},
        {:send,
         sse_frame(%{
           "jsonrpc" => "2.0",
           "id" => "call-sse-stream-1",
           "result" => %{
             "childID" => "child-sse-stream-1",
             "seq" => 3,
             "token" => "done",
             "ok" => true
           }
         })},
        {:sleep, 25}
      ])

    assert {:ok, _transport} =
             SSE.start_link(
               url: "http://127.0.0.1:#{server.port}/mcp/events?session=session-sse-stream-1",
               parent_call_id: "parent-sse-stream-1",
               runtime_source: "synthetic",
               external_ids: %{
                 "session_id" => "session-sse-stream-1",
                 "call_id" => "call-sse-stream-1"
               },
               event_sink: self(),
               timeout: 1_000
             )

    assert_receive {:fake_sse_request, request}, 500
    assert request =~ "GET /mcp/events?session=session-sse-stream-1 HTTP/1.1"

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :transport_connected,
                      transport: :sse,
                      parent_call_id: "parent-sse-stream-1",
                      event_seq: 1
                    }},
                   500

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_event,
                      parent_call_id: "parent-sse-stream-1",
                      notification: %{
                        "params" => %{
                          "childID" => "child-sse-stream-1",
                          "seq" => 1,
                          "token" => "alpha"
                        }
                      },
                      event_seq: 2
                    } = first_token},
                   500

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_event,
                      parent_call_id: "parent-sse-stream-1",
                      notification: %{
                        "params" => %{
                          "childID" => "child-sse-stream-2",
                          "seq" => 1,
                          "token" => "side"
                        }
                      },
                      event_seq: 3
                    } = sibling_token},
                   500

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_event,
                      parent_call_id: "parent-sse-stream-1",
                      notification: %{
                        "params" => %{
                          "childID" => "child-sse-stream-1",
                          "seq" => 2,
                          "token" => "beta"
                        }
                      },
                      event_seq: 4
                    } = second_token},
                   500

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_result,
                      parent_call_id: "parent-sse-stream-1",
                      result: %{
                        "childID" => "child-sse-stream-1",
                        "seq" => 3,
                        "token" => "done",
                        "ok" => true
                      },
                      event_seq: 5
                    } = result},
                   500

    {parent_state, child_state} =
      Enum.reduce(
        [first_token, sibling_token, second_token, result],
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

    assert hierarchy.orphan_children == []

    assert [
             %{
               id: "parent-mcp:parent-sse-stream-1",
               kind: :parent_mcp_call,
               parent_call_id: "parent-sse-stream-1",
               transport: "sse",
               children: [
                 %{
                   id: "child-session:child-sse-stream-1",
                   kind: :child_session,
                   child_id: "child-sse-stream-1",
                   parent_call_id: "parent-sse-stream-1",
                   transport: "sse",
                   pane_state: %{stream_entries: stream_entries}
                 },
                 %{
                   id: "child-session:child-sse-stream-2",
                   kind: :child_session,
                   child_id: "child-sse-stream-2",
                   parent_call_id: "parent-sse-stream-1",
                   transport: "sse",
                   pane_state: %{stream_entries: sibling_stream_entries}
                 }
               ]
             }
           ] = hierarchy.roots

    assert Enum.map(stream_entries, fn entry ->
             Map.take(entry, [:event_seq, :runtime_seq, :token, :type])
           end) == [
             %{event_seq: 2, runtime_seq: 1, token: "alpha", type: :parent_call_event},
             %{event_seq: 4, runtime_seq: 2, token: "beta", type: :parent_call_event},
             %{event_seq: 5, runtime_seq: 3, token: "done", type: :parent_call_result}
           ]

    assert Enum.map(sibling_stream_entries, fn entry ->
             Map.take(entry, [:event_seq, :runtime_seq, :token, :type])
           end) == [
             %{event_seq: 3, runtime_seq: 1, token: "side", type: :parent_call_event}
           ]
  end

  test "ingests synthetic SSE MCP server events seq=1..N without decoded or emitted gaps" do
    event_count = 12
    child_id = "child-seq-sse-1"

    journal_path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-sse-journal-#{System.unique_integer([:positive])}.jsonl"
      )

    on_exit(fn -> File.rm(journal_path) end)

    stream_script =
      [
        {:send,
         [
           "HTTP/1.1 200 OK\r\n",
           "content-type: text/event-stream\r\n",
           "cache-control: no-cache\r\n",
           "connection: keep-alive\r\n",
           "\r\n"
         ]}
      ] ++
        Enum.flat_map(1..event_count, fn seq ->
          [
            {:send,
             sse_frame(%{
               "jsonrpc" => "2.0",
               "method" => "notifications/progress",
               "params" => %{
                 "childID" => child_id,
                 "seq" => seq,
                 "token" => "token-#{seq}"
               }
             })},
            {:sleep, 1}
          ]
        end)

    {:ok, server} = start_fake_sse_server(stream_script)

    assert {:ok, _transport} =
             SSE.start_link(
               url: "http://127.0.0.1:#{server.port}/mcp/events?session=session-seq-sse-1",
               parent_call_id: "parent-seq-sse-1",
               runtime_source: "synthetic",
               external_ids: %{
                 "session_id" => "session-seq-sse-1",
                 "call_id" => "call-seq-sse-1"
               },
               event_sink: self(),
               journal_path: journal_path,
               timeout: 1_000
             )

    assert_receive {:fake_sse_request, request}, 500
    assert request =~ "GET /mcp/events?session=session-seq-sse-1 HTTP/1.1"

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :transport_connected,
                      transport: :sse,
                      parent_call_id: "parent-seq-sse-1",
                      event_seq: 1
                    } = connected_event},
                   500

    stream_events =
      Enum.map(1..event_count, fn seq ->
        assert_receive {:ourocode_event,
                        %LifecycleEvent{
                          type: :parent_call_event,
                          transport: :sse,
                          parent_call_id: "parent-seq-sse-1",
                          notification: %{
                            "jsonrpc" => "2.0",
                            "method" => "notifications/progress",
                            "params" => %{
                              "childID" => ^child_id,
                              "seq" => ^seq,
                              "token" => token
                            }
                          },
                          payload: payload,
                          event_seq: event_seq
                        } = event},
                       500

        assert token == "token-#{seq}"
        assert payload == %{"childID" => child_id, "seq" => seq, "token" => token}
        assert event_seq == seq + 1
        event
      end)

    assert :ok = Journal.verify_no_event_seq_gaps([connected_event | stream_events])

    assert Enum.map(stream_events, fn event -> event.notification["params"]["seq"] end) ==
             Enum.to_list(1..event_count)

    assert Enum.map(stream_events, fn event -> event.payload["seq"] end) ==
             Enum.to_list(1..event_count)

    assert Enum.map(stream_events, & &1.event_seq) == Enum.to_list(2..(event_count + 1))

    child_state =
      Enum.reduce(stream_events, ChildSessionPanes.new(), fn event, state ->
        ChildSessionPanes.apply_event(state, event)
      end)

    assert [
             %{
               child_id: ^child_id,
               parent_call_id: "parent-seq-sse-1",
               transport: :sse,
               stream_cursor: %{event_seq: last_event_seq},
               pane_state: %{stream_entries: stream_entries}
             }
           ] = child_state.working

    assert last_event_seq == event_count + 1
    assert Enum.map(stream_entries, & &1.runtime_seq) == Enum.to_list(1..event_count)
    assert Enum.map(stream_entries, & &1.token) == Enum.map(1..event_count, &"token-#{&1}")

    assert {:ok, journal_entries} = Journal.read_ordered(journal_path)
    stream_journal_entries = Enum.take(journal_entries, event_count + 1)

    assert Enum.map(stream_journal_entries, & &1.event_seq) == Enum.to_list(1..(event_count + 1))

    assert Enum.map(stream_journal_entries, & &1.type) ==
             [:transport_connected] ++ List.duplicate(:parent_call_event, event_count)

    assert Enum.map(Enum.drop(stream_journal_entries, 1), &get_in(&1, [:payload, "seq"])) ==
             Enum.to_list(1..event_count)
  end

  test "live pane adapter displays decoded SSE synthetic MCP events seq=1..N with no gaps" do
    event_count = 12
    child_id = "child-live-sse-1"

    stream_script =
      [
        {:send,
         [
           "HTTP/1.1 200 OK\r\n",
           "content-type: text/event-stream\r\n",
           "cache-control: no-cache\r\n",
           "connection: keep-alive\r\n",
           "\r\n"
         ]}
      ] ++
        Enum.flat_map(1..event_count, fn seq ->
          frame =
            sse_frame(%{
              "jsonrpc" => "2.0",
              "method" => "notifications/progress",
              "params" => %{
                "childID" => child_id,
                "seq" => seq,
                "token" => "live-sse-token-#{seq}"
              }
            })

          frame_binary = IO.iodata_to_binary(frame)
          midpoint = div(byte_size(frame_binary), 2)
          <<first::binary-size(midpoint), second::binary>> = frame_binary

          [
            {:send, first},
            {:sleep, 1},
            {:send, second},
            {:sleep, 1}
          ]
        end)

    {:ok, server} = start_fake_sse_server(stream_script)

    assert {:ok, _transport} =
             SSE.start_link(
               url: "http://127.0.0.1:#{server.port}/mcp/events?session=session-live-sse-1",
               parent_call_id: "parent-live-sse-1",
               runtime_source: "synthetic",
               external_ids: %{
                 "session_id" => "session-live-sse-1",
                 "call_id" => "call-live-sse-1"
               },
               event_sink: self(),
               timeout: 1_000
             )

    assert_receive {:fake_sse_request, request}, 500
    assert request =~ "GET /mcp/events?session=session-live-sse-1 HTTP/1.1"

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :transport_connected,
                      transport: :sse,
                      parent_call_id: "parent-live-sse-1",
                      event_seq: 1
                    } = connected_event},
                   500

    stream_events =
      Enum.map(1..event_count, fn seq ->
        assert_receive {:ourocode_event,
                        %LifecycleEvent{
                          type: :parent_call_event,
                          transport: :sse,
                          parent_call_id: "parent-live-sse-1",
                          notification: %{
                            "method" => "notifications/progress",
                            "params" => %{
                              "childID" => ^child_id,
                              "seq" => ^seq,
                              "token" => token
                            }
                          },
                          payload: payload,
                          event_seq: event_seq
                        } = event},
                       500

        assert token == "live-sse-token-#{seq}"
        assert payload == %{"childID" => child_id, "seq" => seq, "token" => token}
        assert event_seq == seq + 1
        event
      end)

    refute_receive {:ourocode_event, %LifecycleEvent{type: :parent_call_event}}, 50

    assert Enum.map(stream_events, &get_in(&1.notification, ["params", "seq"])) ==
             Enum.to_list(1..event_count)

    assert Enum.map(stream_events, & &1.event_seq) == Enum.to_list(2..(event_count + 1))
    assert :ok = Journal.verify_no_event_seq_gaps([connected_event | stream_events])

    {parent_state, child_state} =
      Enum.reduce(
        stream_events,
        {
          %{working: [], completed: [], focused: nil, open: []},
          ChildSessionPanes.new()
        },
        fn event, {parent_state, child_state} ->
          {
            ParentMcpPane.apply_event(parent_state, event),
            ChildSessionPanes.apply_event(child_state, event)
          }
        end
      )

    assert [
             %{
               child_id: ^child_id,
               parent_call_id: "parent-live-sse-1",
               transport: :sse,
               stream_cursor: %{event_seq: last_stream_event_seq},
               pane_state: %{stream_entries: stream_entries}
             }
           ] = child_state.working

    assert last_stream_event_seq == event_count + 1
    assert Enum.map(stream_entries, & &1.runtime_seq) == Enum.to_list(1..event_count)

    assert Enum.map(stream_entries, & &1.token) ==
             Enum.map(1..event_count, &"live-sse-token-#{&1}")

    rendered_children = ChildSessionPanes.render(child_state)

    assert [
             %{
               child_id: ^child_id,
               transport: "sse",
               stream_event_count: ^event_count,
               pane_state: %{stream_entries: rendered_stream_entries},
               line: rendered_line
             }
           ] = rendered_children.working

    assert Enum.map(rendered_stream_entries, & &1.runtime_seq) == Enum.to_list(1..event_count)

    assert Enum.map(rendered_stream_entries, & &1.token) ==
             Enum.map(1..event_count, &"live-sse-token-#{&1}")

    assert rendered_line =~ "transport=sse"
    assert rendered_line =~ "events=#{event_count}"

    frame = Layout.render_runtime_frame(parent_state, child_state)

    rendered_frame_seqs =
      ~r/(?:stream=\[|\|)(\d+):token=live-sse-token-\d+/
      |> Regex.scan(frame, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.to_integer/1)

    assert rendered_frame_seqs == Enum.to_list(1..event_count)

    tree = UITree.from_panes(parent_state, child_state)

    assert [
             %{
               parent_call_id: "parent-live-sse-1",
               children: [
                 %{
                   child_id: ^child_id,
                   transport: :sse,
                   stream_events: rendered_stream_events
                 }
               ]
             }
           ] = tree.roots

    assert Enum.map(rendered_stream_events, & &1.runtime_seq) == Enum.to_list(1..event_count)

    assert Enum.map(rendered_stream_events, & &1.token) ==
             Enum.map(1..event_count, &"live-sse-token-#{&1}")
  end

  test "transport reconstructs arbitrarily chunked SSE byte streams without loss" do
    event_count = 15
    child_id = "child-chunked-sse-1"

    journal_path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-sse-chunked-journal-#{System.unique_integer([:positive])}.jsonl"
      )

    on_exit(fn -> File.rm(journal_path) end)

    response_headers = [
      "HTTP/1.1 200 OK\r\n",
      "content-type: text/event-stream; charset=utf-8\r\n",
      "cache-control: no-cache\r\n",
      "connection: keep-alive\r\n",
      "\r\n"
    ]

    stream_frames =
      Enum.map(1..event_count, fn seq ->
        sse_frame(
          %{
            "jsonrpc" => "2.0",
            "method" => "notifications/progress",
            "params" => %{
              "childID" => child_id,
              "seq" => seq,
              "token" => "chunked-sse-token-#{seq}"
            }
          },
          id: "chunked-frame-#{seq}"
        )
      end) ++
        [
          sse_frame(
            %{
              "jsonrpc" => "2.0",
              "id" => "call-chunked-sse-1",
              "result" => %{
                "childID" => child_id,
                "seq" => event_count + 1,
                "token" => "chunked-sse-done",
                "ok" => true
              }
            },
            id: "chunked-frame-result"
          )
        ]

    byte_stream = IO.iodata_to_binary([response_headers, stream_frames])

    stream_script =
      byte_stream
      |> chunk_binary([1, 2, 3, 5, 8, 13, 1, 21, 4, 1])
      |> Enum.flat_map(fn chunk -> [{:send, chunk}, {:sleep, 1}] end)

    {:ok, server} = start_fake_sse_server(stream_script)

    assert {:ok, _transport} =
             SSE.start_link(
               url: "http://127.0.0.1:#{server.port}/mcp/events?session=session-chunked-sse-1",
               parent_call_id: "parent-chunked-sse-1",
               runtime_source: "synthetic",
               external_ids: %{
                 "session_id" => "session-chunked-sse-1",
                 "call_id" => "call-chunked-sse-1"
               },
               event_sink: self(),
               journal_path: journal_path,
               timeout: 1_000
             )

    assert_receive {:fake_sse_request, request}, 500
    assert request =~ "GET /mcp/events?session=session-chunked-sse-1 HTTP/1.1"

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :transport_connected,
                      transport: :sse,
                      parent_call_id: "parent-chunked-sse-1",
                      event_seq: 1
                    } = connected_event},
                   500

    stream_events =
      Enum.map(1..event_count, fn seq ->
        assert_receive {:ourocode_event,
                        %LifecycleEvent{
                          type: :parent_call_event,
                          transport: :sse,
                          parent_call_id: "parent-chunked-sse-1",
                          notification: %{
                            "method" => "notifications/progress",
                            "params" => %{
                              "childID" => ^child_id,
                              "seq" => ^seq,
                              "token" => token
                            }
                          },
                          payload: payload,
                          event_seq: event_seq,
                          raw_event: %{"id" => sse_id}
                        } = event},
                       5_000

        assert token == "chunked-sse-token-#{seq}"
        assert payload == %{"childID" => child_id, "seq" => seq, "token" => token}
        assert event_seq == seq + 1
        assert sse_id == "chunked-frame-#{seq}"
        event
      end)

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_result,
                      transport: :sse,
                      parent_call_id: "parent-chunked-sse-1",
                      call_id: "call-chunked-sse-1",
                      request_id: "call-chunked-sse-1",
                      result: %{
                        "childID" => ^child_id,
                        "seq" => result_seq,
                        "token" => "chunked-sse-done",
                        "ok" => true
                      },
                      event_seq: result_event_seq,
                      raw_event: %{"id" => "chunked-frame-result"}
                    } = result_event},
                   5_000

    assert result_seq == event_count + 1
    assert result_event_seq == event_count + 2
    refute_receive {:ourocode_event, %LifecycleEvent{type: :transport_decode_failed}}, 50

    all_events = [connected_event | stream_events] ++ [result_event]
    assert :ok = Journal.verify_no_event_seq_gaps(all_events)

    assert Enum.map(stream_events, &get_in(&1.notification, ["params", "seq"])) ==
             Enum.to_list(1..event_count)

    assert Enum.map(stream_events, & &1.event_seq) == Enum.to_list(2..(event_count + 1))
  end

  test "persists decoded SSE synthetic MCP server events seq=1..N without journal gaps" do
    event_count = 9
    child_id = "child-journal-sse-1"

    journal_path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-sse-persist-journal-#{System.unique_integer([:positive])}.jsonl"
      )

    on_exit(fn -> File.rm(journal_path) end)

    stream_script =
      [
        {:send,
         [
           "HTTP/1.1 200 OK\r\n",
           "content-type: text/event-stream\r\n",
           "cache-control: no-cache\r\n",
           "connection: keep-alive\r\n",
           "\r\n"
         ]}
      ] ++
        Enum.flat_map(1..event_count, fn seq ->
          frame =
            sse_frame(%{
              "jsonrpc" => "2.0",
              "method" => "notifications/progress",
              "params" => %{
                "childID" => child_id,
                "seq" => seq,
                "token" => "journal-sse-token-#{seq}"
              }
            })

          [
            {:send, frame},
            {:sleep, 1}
          ]
        end) ++
        [{:sleep, 250}]

    {:ok, server} = start_fake_sse_server(stream_script)

    assert {:ok, _transport} =
             SSE.start_link(
               url: "http://127.0.0.1:#{server.port}/mcp/events?session=session-sse-journal-1",
               parent_call_id: "parent-sse-journal-1",
               runtime_source: "synthetic",
               external_ids: %{
                 "session_id" => "session-sse-journal-1",
                 "call_id" => "call-sse-journal-1"
               },
               event_sink: self(),
               journal_path: journal_path,
               timeout: 1_000
             )

    assert_receive {:fake_sse_request, raw_request}, 500
    assert raw_request =~ "GET /mcp/events?session=session-sse-journal-1 HTTP/1.1"

    received_events =
      Enum.map(1..(event_count + 1), fn expected_seq ->
        assert_receive {:ourocode_event, %LifecycleEvent{event_seq: ^expected_seq} = event}, 500
        event
      end)

    assert :ok = Journal.verify_no_event_seq_gaps(received_events)
    assert {:ok, journal_entries} = Journal.read_ordered(journal_path)
    assert Enum.map(journal_entries, & &1.event_seq) == Enum.to_list(1..length(journal_entries))

    stream_journal_entries = Enum.take(journal_entries, event_count + 1)

    assert Enum.map(stream_journal_entries, & &1.event_seq) == Enum.to_list(1..(event_count + 1))

    assert Enum.map(stream_journal_entries, & &1.type) ==
             [:transport_connected] ++ List.duplicate(:parent_call_event, event_count)

    stream_entries = Enum.filter(stream_journal_entries, &(&1.type == :parent_call_event))

    assert Enum.map(stream_entries, &get_in(&1, [:notification, "params", "seq"])) ==
             Enum.to_list(1..event_count)

    assert Enum.map(stream_entries, &get_in(&1, [:payload, "seq"])) ==
             Enum.to_list(1..event_count)

    assert Enum.map(stream_entries, &get_in(&1, [:notification, "params", "token"])) ==
             Enum.map(1..event_count, &"journal-sse-token-#{&1}")

    assert [
             %{
               type: :parent_call_event,
               transport: :sse,
               parent_call_id: "parent-sse-journal-1",
               runtime_source: "synthetic",
               external_ids: %{
                 "session_id" => "session-sse-journal-1",
                 "call_id" => "call-sse-journal-1",
                 childID: ^child_id
               }
             }
             | _
           ] = stream_entries
  end

  test "awaits an SSE response stream result as the parent MCP call success outcome" do
    {:ok, server} =
      start_fake_sse_dispatch_server(%{
        "jsonrpc" => "2.0",
        "id" => "call-1",
        "result" => %{"childID" => "child-1", "seq" => 1, "ok" => true}
      })

    assert {:ok, transport} =
             SSE.start_link(
               url: "http://127.0.0.1:#{server.port}/mcp/events?session=session-1",
               dispatch_url: "http://127.0.0.1:#{server.port}/mcp/messages?session=session-1",
               parent_call_id: "parent-sse-await-success",
               runtime_source: "synthetic",
               external_ids: %{"session_id" => "session-1"},
               event_sink: self(),
               timeout: 1_000
             )

    assert_receive {:ourocode_event, %LifecycleEvent{type: :transport_connected}}, 500

    assert {:ok, %{"childID" => "child-1", "seq" => 1, "ok" => true}} =
             SSE.call_parent(
               transport,
               "tools/call",
               %{"name" => "ooo.run", "arguments" => %{"task" => "ping"}},
               request_id: "call-1",
               await_response: true,
               timeout: 1_000
             )

    assert_receive {:fake_sse_dispatch_request, dispatch_request}, 500
    assert dispatch_request =~ "POST /mcp/messages?session=session-1 HTTP/1.1"

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_started,
                      transport: :sse,
                      parent_call_id: "parent-sse-await-success",
                      request_id: "call-1",
                      event_seq: 2
                    }},
                   500

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_result,
                      transport: :sse,
                      parent_call_id: "parent-sse-await-success",
                      call_id: "call-1",
                      request_id: "call-1",
                      method: "tools/call",
                      params: %{"name" => "ooo.run", "arguments" => %{"task" => "ping"}},
                      payload: %{"childID" => "child-1", "seq" => 1, "ok" => true},
                      result: %{"childID" => "child-1", "seq" => 1, "ok" => true},
                      event_seq: 3,
                      status: 200
                    }},
                   500
  end

  test "awaits an SSE response stream error as the parent MCP call failure outcome" do
    rpc_error = %{"code" => -32_000, "message" => "child launch failed"}

    {:ok, server} =
      start_fake_sse_dispatch_server(%{
        "jsonrpc" => "2.0",
        "id" => "call-1",
        "error" => rpc_error
      })

    assert {:ok, transport} =
             SSE.start_link(
               url: "http://127.0.0.1:#{server.port}/mcp/events?session=session-1",
               dispatch_url: "http://127.0.0.1:#{server.port}/mcp/messages?session=session-1",
               parent_call_id: "parent-sse-await-failure",
               runtime_source: "synthetic",
               external_ids: %{"session_id" => "session-1"},
               event_sink: self(),
               timeout: 1_000
             )

    assert_receive {:ourocode_event, %LifecycleEvent{type: :transport_connected}}, 500

    assert {:error, ^rpc_error} =
             SSE.call_parent(
               transport,
               "tools/call",
               %{"name" => "ooo.run", "arguments" => %{"task" => "ping"}},
               request_id: "call-1",
               await_response: true,
               timeout: 1_000
             )

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_failed,
                      transport: :sse,
                      parent_call_id: "parent-sse-await-failure",
                      call_id: "call-1",
                      request_id: "call-1",
                      method: "tools/call",
                      params: %{"name" => "ooo.run", "arguments" => %{"task" => "ping"}},
                      error: ^rpc_error,
                      error_details: ^rpc_error,
                      event_seq: 3,
                      status: 200
                    }},
                   500
  end

  test "delivers the first SSE token within five seconds after childID creation" do
    {:ok, server} =
      start_fake_sse_server([
        {:send,
         [
           "HTTP/1.1 200 OK\r\n",
           "content-type: text/event-stream\r\n",
           "cache-control: no-cache\r\n",
           "connection: keep-alive\r\n",
           "\r\n"
         ]},
        {:send,
         sse_frame(%{
           "jsonrpc" => "2.0",
           "method" => "notifications/progress",
           "params" => %{
             "childID" => "child-sse-timing-1",
             "phase" => "created"
           }
         })},
        {:sleep, 50},
        {:send,
         sse_frame(%{
           "jsonrpc" => "2.0",
           "method" => "notifications/progress",
           "params" => %{
             "childID" => "child-sse-timing-1",
             "seq" => 1,
             "token" => "first-sse-token"
           }
         })},
        {:send,
         sse_frame(%{
           "jsonrpc" => "2.0",
           "id" => "call-sse-timing-1",
           "result" => %{
             "childID" => "child-sse-timing-1",
             "seq" => 2,
             "ok" => true
           }
         })},
        {:sleep, 25}
      ])

    assert {:ok, _transport} =
             SSE.start_link(
               url: "http://127.0.0.1:#{server.port}/mcp/events?session=session-sse-timing-1",
               parent_call_id: "parent-sse-timing-1",
               runtime_source: "synthetic",
               external_ids: %{
                 "session_id" => "session-sse-timing-1",
                 "call_id" => "call-sse-timing-1"
               },
               event_sink: self(),
               timeout: 1_000
             )

    assert_receive {:fake_sse_request, request}, 500
    assert request =~ "GET /mcp/events?session=session-sse-timing-1 HTTP/1.1"

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :transport_connected,
                      transport: :sse,
                      parent_call_id: "parent-sse-timing-1",
                      event_seq: 1
                    }},
                   500

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_event,
                      transport: :sse,
                      parent_call_id: "parent-sse-timing-1",
                      notification: %{
                        "params" => %{
                          "childID" => "child-sse-timing-1",
                          "phase" => "created"
                        }
                      },
                      event_seq: 2
                    } = child_created_event},
                   500

    child_created_at = System.monotonic_time(:millisecond)

    child_state =
      ChildSessionPanes.new()
      |> ChildSessionPanes.apply_event(child_created_event)

    assert [
             %{
               id: "child-session:child-sse-timing-1",
               child_id: "child-sse-timing-1",
               parent_call_id: "parent-sse-timing-1",
               transport: :sse,
               stream_cursor: %{event_seq: child_created_seq},
               pane_state: %{stream_entries: []}
             }
           ] = child_state.working

    assert child_created_seq == child_created_event.event_seq

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_event,
                      transport: :sse,
                      parent_call_id: "parent-sse-timing-1",
                      notification: %{
                        "params" => %{
                          "childID" => "child-sse-timing-1",
                          "seq" => 1,
                          "token" => "first-sse-token"
                        }
                      },
                      event_seq: 3
                    } = first_token_event},
                   5_000

    first_token_at = System.monotonic_time(:millisecond)
    assert first_token_at - child_created_at <= 5_000
    assert first_token_event.occurred_at_ms - child_created_event.occurred_at_ms <= 5_000

    child_state = ChildSessionPanes.apply_event(child_state, first_token_event)

    assert [
             %{
               id: "child-session:child-sse-timing-1",
               child_id: "child-sse-timing-1",
               parent_call_id: "parent-sse-timing-1",
               transport: :sse,
               stream_cursor: %{event_seq: first_token_seq},
               pane_state: %{
                 stream_entries: [
                   %{
                     event_seq: first_token_seq,
                     runtime_seq: 1,
                     token: "first-sse-token",
                     payload: %{
                       "childID" => "child-sse-timing-1",
                       "seq" => 1,
                       "token" => "first-sse-token"
                     }
                   }
                 ]
               }
             }
           ] = child_state.working

    assert first_token_seq == first_token_event.event_seq

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_result,
                      transport: :sse,
                      parent_call_id: "parent-sse-timing-1",
                      result: %{
                        "childID" => "child-sse-timing-1",
                        "seq" => 2,
                        "ok" => true
                      },
                      event_seq: 4
                    }},
                   500
  end

  test "routes the first SSE token for an existing childID to its child pane" do
    {:ok, server} =
      start_fake_sse_server([
        {:send,
         [
           "HTTP/1.1 200 OK\r\n",
           "content-type: text/event-stream\r\n",
           "cache-control: no-cache\r\n",
           "connection: keep-alive\r\n",
           "\r\n"
         ]},
        {:send,
         sse_frame(%{
           "jsonrpc" => "2.0",
           "method" => "notifications/progress",
           "params" => %{
             "childID" => "child-sse-existing-1",
             "seq" => 1,
             "token" => "first-existing-sse-token",
             "cursor" => %{"offset" => 1}
           }
         })},
        {:send,
         sse_frame(%{
           "jsonrpc" => "2.0",
           "id" => "call-sse-existing-1",
           "result" => %{
             "childID" => "child-sse-existing-1",
             "seq" => 2,
             "token" => "done",
             "ok" => true
           }
         })},
        {:sleep, 25}
      ])

    existing_child_state =
      ChildSessionPanes.new()
      |> ChildSessionPanes.apply_event(%{
        type: :child_pane_registered,
        pane_id: "child-pane:stable-existing-sse",
        child_id: "child-sse-existing-1",
        parent_call_id: "parent-sse-existing-1",
        runtime_source: "synthetic",
        transport: :sse,
        external_ids: %{
          "session_id" => "session-sse-existing-1",
          "call_id" => "call-sse-existing-1"
        },
        pane_state: %{title: "Existing SSE child", stream_entries: []},
        created_at_ms: 10,
        updated_at_ms: 10
      })

    started_at = System.monotonic_time(:millisecond)

    assert {:ok, _transport} =
             SSE.start_link(
               url: "http://127.0.0.1:#{server.port}/mcp/events?session=session-sse-existing-1",
               parent_call_id: "parent-sse-existing-1",
               runtime_source: "synthetic",
               external_ids: %{
                 "session_id" => "session-sse-existing-1",
                 "call_id" => "call-sse-existing-1"
               },
               event_sink: self(),
               timeout: 1_000
             )

    assert_receive {:fake_sse_request, request}, 500
    assert request =~ "GET /mcp/events?session=session-sse-existing-1 HTTP/1.1"

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :transport_connected,
                      transport: :sse,
                      parent_call_id: "parent-sse-existing-1",
                      event_seq: 1
                    } = connected},
                   500

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_event,
                      transport: :sse,
                      parent_call_id: "parent-sse-existing-1",
                      notification: %{
                        "params" => %{
                          "childID" => "child-sse-existing-1",
                          "seq" => 1,
                          "token" => "first-existing-sse-token",
                          "cursor" => %{"offset" => 1}
                        }
                      },
                      event_seq: 2
                    } = first_token},
                   5_000

    assert System.monotonic_time(:millisecond) - started_at <= 5_000
    assert first_token.occurred_at_ms - connected.occurred_at_ms <= 5_000

    routed_child_state = ChildSessionPanes.apply_event(existing_child_state, first_token)

    assert [
             %{
               id: "child-pane:stable-existing-sse",
               child_id: "child-sse-existing-1",
               parent_call_id: "parent-sse-existing-1",
               runtime_source: "synthetic",
               transport: :sse,
               external_ids: %{
                 "session_id" => "session-sse-existing-1",
                 "call_id" => "call-sse-existing-1",
                 "childID" => "child-sse-existing-1"
               },
               stream_cursor: %{
                 :transport => :sse,
                 :event_seq => 2,
                 :child_id => "child-sse-existing-1",
                 "offset" => 1
               },
               pane_state: %{
                 title: "Existing SSE child",
                 stream_entries: [
                   %{
                     event_seq: 2,
                     runtime_seq: 1,
                     token: "first-existing-sse-token",
                     payload: %{
                       "childID" => "child-sse-existing-1",
                       "seq" => 1,
                       "token" => "first-existing-sse-token",
                       "cursor" => %{"offset" => 1}
                     }
                   }
                 ]
               }
             }
           ] = routed_child_state.working

    assert routed_child_state.child_pane_registry == %{
             "child-sse-existing-1" => "child-pane:stable-existing-sse"
           }

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_result,
                      transport: :sse,
                      parent_call_id: "parent-sse-existing-1",
                      result: %{
                        "childID" => "child-sse-existing-1",
                        "seq" => 2,
                        "token" => "done",
                        "ok" => true
                      },
                      event_seq: 3
                    } = result},
                   500

    final_child_state = ChildSessionPanes.apply_event(routed_child_state, result)

    parent_state =
      Enum.reduce(
        [first_token, result],
        %{working: [], completed: [], focused: nil, open: []},
        &ParentMcpPane.apply_event(&2, &1)
      )

    hierarchy = Layout.parent_child_hierarchy(parent_state, final_child_state)

    assert [
             %{
               id: "parent-mcp:parent-sse-existing-1",
               children: [
                 %{
                   id: "child-pane:stable-existing-sse",
                   child_id: "child-sse-existing-1",
                   pane_state: %{
                     stream_entries: [
                       %{event_seq: 2, runtime_seq: 1, token: "first-existing-sse-token"},
                       %{event_seq: 3, runtime_seq: 2, token: "done"}
                     ]
                   }
                 }
               ]
             }
           ] = hierarchy.roots

    assert hierarchy.orphan_children == []
  end

  test "emits a failure event when the SSE endpoint rejects the connection" do
    {:ok, server} =
      start_fake_sse_server([
        {:send,
         [
           "HTTP/1.1 500 Internal Server Error\r\n",
           "content-type: text/plain\r\n",
           "content-length: 6\r\n",
           "connection: close\r\n",
           "\r\n",
           "failed"
         ]}
      ])

    assert {:ok, _transport} =
             SSE.start_link(
               url: "http://127.0.0.1:#{server.port}/mcp/events",
               parent_call_id: "parent-sse-fail",
               runtime_source: "synthetic",
               event_sink: self(),
               timeout: 1_000
             )

    assert_receive {:fake_sse_request, request}, 500
    assert request =~ "GET /mcp/events HTTP/1.1"

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :transport_failed,
                      transport: :sse,
                      parent_call_id: "parent-sse-fail",
                      runtime_source: "synthetic",
                      event_seq: 1,
                      status: 500,
                      error: {:http_error, 500}
                    }},
                   500
  end

  defp sse_frame(json_rpc, opts \\ []) do
    [
      "event: ",
      Keyword.get(opts, :event, "message"),
      "\n",
      optional_sse_id(opts[:id]),
      "data: ",
      Json.encode!(json_rpc),
      "\n\n"
    ]
  end

  defp optional_sse_id(nil), do: []
  defp optional_sse_id(id), do: ["id: ", to_string(id), "\n"]

  defp chunk_binary(binary, sizes) when is_binary(binary) and is_list(sizes) do
    do_chunk_binary(binary, sizes, 0, [])
  end

  defp do_chunk_binary("", _sizes, _index, chunks), do: Enum.reverse(chunks)

  defp do_chunk_binary(binary, sizes, index, chunks) do
    chunk_size =
      sizes
      |> Enum.at(rem(index, length(sizes)))
      |> min(byte_size(binary))

    <<chunk::binary-size(chunk_size), rest::binary>> = binary
    do_chunk_binary(rest, sizes, index + 1, [chunk | chunks])
  end

  defp start_fake_sse_server(script) do
    parent = self()

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen_socket)

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, request} = recv_http_headers(socket, "")
        send(parent, {:fake_sse_request, request})

        Enum.each(script, fn
          {:send, data} -> :ok = :gen_tcp.send(socket, data)
          {:sleep, milliseconds} -> Process.sleep(milliseconds)
        end)

        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
      end)

    {:ok, %{pid: pid, port: port}}
  end

  defp start_fake_sse_dispatch_server(
         stream_response \\ %{
           "jsonrpc" => "2.0",
           "id" => "call-1",
           "result" => %{"childID" => "child-1", "seq" => 1, "ok" => true}
         }
       ) do
    parent = self()

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen_socket)

    pid =
      spawn_link(fn ->
        {:ok, sse_socket} = :gen_tcp.accept(listen_socket)
        {:ok, request} = recv_http_headers(sse_socket, "")
        send(parent, {:fake_sse_request, request})

        :ok =
          :gen_tcp.send(sse_socket, [
            "HTTP/1.1 200 OK\r\n",
            "content-type: text/event-stream\r\n",
            "cache-control: no-cache\r\n",
            "connection: keep-alive\r\n",
            "\r\n"
          ])

        {:ok, dispatch_socket} = :gen_tcp.accept(listen_socket)
        {:ok, dispatch_request} = recv_http_request(dispatch_socket, "")
        send(parent, {:fake_sse_dispatch_request, dispatch_request})

        response_body = Json.encode!(%{accepted: true}) |> IO.iodata_to_binary()

        :ok =
          :gen_tcp.send(dispatch_socket, [
            "HTTP/1.1 202 Accepted\r\n",
            "content-type: application/json\r\n",
            "content-length: #{byte_size(response_body)}\r\n",
            "connection: close\r\n",
            "\r\n",
            response_body
          ])

        :gen_tcp.close(dispatch_socket)

        :ok =
          :gen_tcp.send(
            sse_socket,
            sse_frame(stream_response)
          )

        Process.sleep(25)
        :gen_tcp.close(sse_socket)
        :gen_tcp.close(listen_socket)
      end)

    {:ok, %{pid: pid, port: port}}
  end

  defp recv_http_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, chunk} ->
        next = acc <> chunk

        if String.contains?(next, "\r\n\r\n") do
          {:ok, next}
        else
          recv_http_headers(socket, next)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recv_http_request(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, chunk} ->
        next = acc <> chunk

        if complete_http_request?(next) do
          {:ok, next}
        else
          recv_http_request(socket, next)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp complete_http_request?(request) do
    with [headers, body] <- String.split(request, "\r\n\r\n", parts: 2),
         [length] <- Regex.run(~r/content-length:\s*(\d+)/i, headers, capture: :all_but_first),
         {content_length, ""} <- Integer.parse(length) do
      byte_size(body) >= content_length
    else
      _ -> false
    end
  end
end
