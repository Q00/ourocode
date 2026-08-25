defmodule Ourocode.Runtime.ChildSessionPollerTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionPanes
  alias Ourocode.Dashboard.ChildSessionStreamEntry
  alias Ourocode.MCP.ParentCallResult
  alias Ourocode.Runtime.ChildSessionPoller
  alias Ourocode.Runtime.LoopBindingEventFlow
  alias Ourocode.Runtime.LoopBindingState

  defp status_response(job_id, status) do
    %ParentCallResult{
      parent_call_id: "parent-poll-1",
      runtime_source: "ouroboros",
      transport: :streamable_http,
      external_ids: %{"job_id" => job_id},
      response: %{
        "result" => %{
          "content" => [
            %{"type" => "text", "text" => job_id <> " " <> status <> " plan AC 1/3"}
          ],
          "_meta" => %{
            "job_id" => job_id,
            "status" => status,
            "is_terminal" => status in ["completed", "failed", "cancelled", "interrupted"]
          }
        }
      }
    }
  end

  defp sequenced_status_caller(test_pid, statuses) do
    {:ok, seq} = Agent.start_link(fn -> statuses end)

    fn opts, payload ->
      status = Agent.get_and_update(seq, fn [head | tail] -> {head, tail ++ [head]} end)
      send(test_pid, {:status_called, opts[:url], payload, status})
      {:ok, status_response(payload["params"]["arguments"]["job_id"], status)}
    end
  end

  test "polls job status into the inbox and stops at the terminal status" do
    {:ok, agent} = Agent.start_link(&LoopBindingState.initial/0)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    status_caller = sequenced_status_caller(self(), ["running", "running", "completed"])

    poller =
      ChildSessionPoller.start(agent,
        child_id: "job-poll-1",
        job_id: "job-poll-1",
        parent_call_id: "parent-poll-1",
        mcp_url: "http://127.0.0.1:4000/mcp",
        status_caller: status_caller,
        interval_ms: 1
      )

    monitor_ref = Process.monitor(poller)
    assert_receive {:DOWN, ^monitor_ref, :process, ^poller, _reason}, 2_000

    assert_receive {:status_called, "http://127.0.0.1:4000/mcp", payload, "running"}
    assert payload["method"] == "tools/call"
    assert payload["params"]["name"] == "ouroboros_job_status"
    assert payload["params"]["arguments"] == %{"job_id" => "job-poll-1", "view" => "compact"}

    assert_receive {:status_called, _url, _second_payload, "running"}
    assert_receive {:status_called, _url, _third_payload, "completed"}

    poll = LoopBindingEventFlow.poll_fun(agent)

    events =
      Stream.repeatedly(fn -> poll.(%{}) end)
      |> Enum.take_while(&match?({:ok, _event}, &1))
      |> Enum.map(fn {:ok, event} -> event end)

    assert length(events) == 3
    assert Enum.map(events, & &1.status) == ["running", "running", "completed"]

    # Non-terminal polls stream as :parent_call_event; the final terminal poll
    # flips to :parent_call_result so the pane leaves :working.
    assert Enum.map(events, & &1.type) ==
             [:parent_call_event, :parent_call_event, :parent_call_result]

    assert Enum.all?(events, fn event ->
             event.runtime_source == "ouroboros" and
               event.transport == :streamable_http and
               event.child_id == "job-poll-1" and
               event.parent_call_id == "parent-poll-1"
           end)

    # No fourth poll after the terminal status.
    refute_receive {:status_called, _url, _payload, _status}, 50

    # Each polled event yields a renderable stream entry.
    final_event = List.last(events)

    assert [entry] = ChildSessionStreamEntry.entries_for_event(final_event, 3, 1_234)
    assert entry.runtime_seq == 3
    assert entry.content == "job-poll-1 completed plan AC 1/3"

    # The fold path surfaced the polled progress in the child pane and the
    # terminal :parent_call_result flipped the pane out of :working.
    rendered_child =
      agent
      |> Agent.get(& &1.child)
      |> ChildSessionPanes.render()

    assert rendered_child.working == []

    assert [%{child_id: "job-poll-1", status: "completed", pane_state: pane_state}] =
             rendered_child.completed

    contents = Enum.map(pane_state.stream_entries, & &1.content)
    assert "job-poll-1 completed plan AC 1/3" in contents
    assert "job-poll-1 running plan AC 1/3" in contents
  end

  test "a terminal failure status also flips the pane out of :working" do
    {:ok, agent} = Agent.start_link(&LoopBindingState.initial/0)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    status_caller = sequenced_status_caller(self(), ["running", "failed"])

    poller =
      ChildSessionPoller.start(agent,
        child_id: "job-poll-4",
        job_id: "job-poll-4",
        parent_call_id: "parent-poll-4",
        mcp_url: "http://127.0.0.1:4000/mcp",
        status_caller: status_caller,
        interval_ms: 1
      )

    monitor_ref = Process.monitor(poller)
    assert_receive {:DOWN, ^monitor_ref, :process, ^poller, _reason}, 2_000

    poll = LoopBindingEventFlow.poll_fun(agent)

    events =
      Stream.repeatedly(fn -> poll.(%{}) end)
      |> Enum.take_while(&match?({:ok, _event}, &1))
      |> Enum.map(fn {:ok, event} -> event end)

    assert Enum.map(events, & &1.type) == [:parent_call_event, :parent_call_result]
    assert List.last(events).status == "failed"

    rendered_child =
      agent
      |> Agent.get(& &1.child)
      |> ChildSessionPanes.render()

    assert rendered_child.working == []

    # Child pane status vocabulary is :working | :completed, so a terminal
    # failure lands in the completed bucket; the failure text stays visible in
    # the stream entries.
    assert [%{child_id: "job-poll-4", status: "completed", pane_state: pane_state}] =
             rendered_child.completed

    contents = Enum.map(pane_state.stream_entries, & &1.content)
    assert "job-poll-4 failed plan AC 1/3" in contents
  end

  test "stops when the poll budget is exhausted and flips the pane out of :working" do
    {:ok, agent} = Agent.start_link(&LoopBindingState.initial/0)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    status_caller = sequenced_status_caller(self(), ["running"])

    poller =
      ChildSessionPoller.start(agent,
        child_id: "job-poll-2",
        job_id: "job-poll-2",
        parent_call_id: "parent-poll-2",
        mcp_url: "http://127.0.0.1:4000/mcp",
        status_caller: status_caller,
        interval_ms: 1,
        max_polls: 2
      )

    monitor_ref = Process.monitor(poller)
    assert_receive {:DOWN, ^monitor_ref, :process, ^poller, _reason}, 2_000

    poll = LoopBindingEventFlow.poll_fun(agent)

    events =
      Stream.repeatedly(fn -> poll.(%{}) end)
      |> Enum.take_while(&match?({:ok, _event}, &1))
      |> Enum.map(fn {:ok, event} -> event end)

    # 2 polled :parent_call_event progress entries plus one final
    # :parent_call_result terminal event so the pane cannot spin forever.
    assert length(events) == 3
    assert Enum.map(events, & &1.status) == ["running", "running", "poll_budget_exhausted"]

    assert Enum.map(events, & &1.type) ==
             [:parent_call_event, :parent_call_event, :parent_call_result]

    rendered_child =
      agent
      |> Agent.get(& &1.child)
      |> ChildSessionPanes.render()

    assert rendered_child.working == []

    assert [%{child_id: "job-poll-2", status: "completed", pane_state: pane_state}] =
             rendered_child.completed

    contents = Enum.map(pane_state.stream_entries, & &1.content)
    assert "Ouroboros job job-poll-2 status polling stopped (budget exhausted)" in contents
  end

  test "tolerates transient status errors and keeps polling until terminal" do
    {:ok, agent} = Agent.start_link(&LoopBindingState.initial/0)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    {:ok, seq} = Agent.start_link(fn -> [:error, :completed] end)

    status_caller = fn _opts, payload ->
      case Agent.get_and_update(seq, fn [head | tail] -> {head, tail ++ [head]} end) do
        :error ->
          {:error, :econnrefused}

        :completed ->
          {:ok, status_response(payload["params"]["arguments"]["job_id"], "completed")}
      end
    end

    poller =
      ChildSessionPoller.start(agent,
        child_id: "job-poll-3",
        job_id: "job-poll-3",
        parent_call_id: "parent-poll-3",
        mcp_url: "http://127.0.0.1:4000/mcp",
        status_caller: status_caller,
        interval_ms: 1
      )

    monitor_ref = Process.monitor(poller)
    assert_receive {:DOWN, ^monitor_ref, :process, ^poller, _reason}, 2_000

    poll = LoopBindingEventFlow.poll_fun(agent)
    assert {:ok, event} = poll.(%{})
    assert event.status == "completed"
    assert :none = poll.(%{})
  end

  test "reuses one owned MCP session and closes it once" do
    {:ok, agent} = Agent.start_link(&LoopBindingState.initial/0)
    parent = self()

    opener = fn _url, options, _protocol, _timeout ->
      send(parent, :session_opened)
      {:ok, Keyword.put(options, :headers, [{"mcp-session-id", "session-1"}]), true}
    end

    closer = fn _url, options, _timeout ->
      send(parent, {:session_closed, options[:headers]})
      :ok
    end

    poller =
      ChildSessionPoller.start(agent,
        child_id: "job-session",
        job_id: "job-session",
        parent_call_id: "parent-session",
        mcp_url: "http://127.0.0.1:4000/mcp",
        session_opener: opener,
        session_closer: closer,
        status_caller: fn options, payload ->
          send(parent, {:status_session, options[:headers]})
          {:ok, status_response(payload["params"]["arguments"]["job_id"], "completed")}
        end,
        interval_ms: 1
      )

    monitor_ref = Process.monitor(poller)
    assert_receive {:DOWN, ^monitor_ref, :process, ^poller, _reason}, 2_000
    assert_receive :session_opened
    assert_receive {:status_session, [{"mcp-session-id", "session-1"}]}
    assert_receive {:session_closed, [{"mcp-session-id", "session-1"}]}
    refute_receive :session_opened, 20
  end

  test "poller exits when its loop bindings owner stops" do
    {:ok, agent} = Agent.start_link(&LoopBindingState.initial/0)

    poller =
      ChildSessionPoller.start(agent,
        child_id: "job-owner",
        job_id: "job-owner",
        parent_call_id: "parent-owner",
        mcp_url: "http://127.0.0.1:4000/mcp",
        status_caller: fn _options, _payload -> {:error, :econnrefused} end,
        interval_ms: 60_000
      )

    monitor_ref = Process.monitor(poller)
    Ourocode.Runtime.LoopBindings.stop(agent)
    assert_receive {:DOWN, ^monitor_ref, :process, ^poller, _reason}, 1_000
  end
end
