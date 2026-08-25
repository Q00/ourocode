defmodule Ourocode.Runtime.ChildSessionPoller do
  @moduledoc """
  Background status poller for job-backed Ouroboros child sessions.

  Background workflow tools (`ooo run`/`ooo auto`/`ooo ralph`, i.e. the
  `start_*` family) return as soon as the job is queued, while the real work
  keeps happening server-side. Without a feed, the registered child pane only
  ever shows the start entry. This poller periodically calls the
  `ouroboros_job_status` MCP tool and enqueues each compact status snapshot as
  a child stream event via `LoopBindings.enqueue/2` — the inbox/fold path that
  the renderer already consumes (never `route_event`; see the
  `project-route-event-seq` constraint).

  Polling stops when the job reports a terminal status (`completed`, `failed`,
  `cancelled`, `interrupted`, or meta `is_terminal: true`) or when `max_polls`
  is exhausted. Transient transport errors are tolerated: the poller skips the
  tick and retries until the poll budget runs out.
  """

  alias Ourocode.MCP.Transport.StreamableHTTP
  alias Ourocode.MCP.Transport.StreamableHTTP.Session
  alias Ourocode.Runtime.{InterviewResponse, LoopBindings}

  @default_interval_ms 2_500
  # ~10 minutes at the default interval.
  @default_max_polls 240
  @poll_timeout_ms 15_000
  @terminal_statuses ["completed", "failed", "cancelled", "interrupted"]
  @protocol_version "2025-06-18"

  @doc """
  Spawns the polling loop. Required opts: `:child_id`, `:job_id`,
  `:parent_call_id`, `:mcp_url`. Injectable: `:status_caller` (defaults to
  `StreamableHTTP.execute_parent_call/2`), `:interval_ms`, `:max_polls`.
  """
  @spec start(pid(), keyword()) :: pid()
  def start(agent, opts) when is_pid(agent) and is_list(opts) do
    status_caller = Keyword.get(opts, :status_caller, &StreamableHTTP.execute_parent_call/2)

    session_opener =
      Keyword.get(opts, :session_opener) ||
        if Keyword.has_key?(opts, :status_caller) do
          fn _url, options, _protocol, _timeout -> {:ok, options, false} end
        else
          &Session.open_owned/4
        end

    ctx = %{
      child_id: Keyword.fetch!(opts, :child_id),
      job_id: Keyword.fetch!(opts, :job_id),
      parent_call_id: Keyword.fetch!(opts, :parent_call_id),
      mcp_url: Keyword.fetch!(opts, :mcp_url),
      status_caller: status_caller,
      session_opener: session_opener,
      session_closer: Keyword.get(opts, :session_closer, &Session.terminate/3),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      max_polls: Keyword.get(opts, :max_polls, @default_max_polls)
    }

    LoopBindings.spawn_worker(agent, fn -> run_session(agent, ctx) end)
  end

  defp run_session(agent, ctx) do
    base_options = [
      url: ctx.mcp_url,
      parent_call_id: ctx.parent_call_id,
      runtime_source: "ouroboros",
      mcp_session: true,
      timeout: @poll_timeout_ms
    ]

    case ctx.session_opener.(ctx.mcp_url, base_options, @protocol_version, @poll_timeout_ms) do
      {:ok, request_options, owned?} ->
        if owned? do
          LoopBindings.register_worker_cleanup(fn ->
            ctx.session_closer.(ctx.mcp_url, request_options, @poll_timeout_ms)
          end)
        end

        loop(agent, Map.put(ctx, :request_options, request_options), 1)

      _error ->
        :ok
    end
  end

  defp loop(agent, ctx, poll_seq) do
    if poll_seq > ctx.max_polls do
      # Budget exhausted without a terminal status: emit one final
      # `:parent_call_result` so the pane flips out of `:working` instead of
      # spinning forever. Reuses the same terminal event path as a real
      # terminal status; `ChildSessionPaneEvent.status_for/1` treats
      # `"poll_budget_exhausted"` as a (non-success) terminal status.
      LoopBindings.enqueue(agent, budget_exhausted_event(ctx, poll_seq))
      :ok
    else
      case poll_once(agent, ctx, poll_seq) do
        :stop ->
          :ok

        :continue ->
          :timer.sleep(ctx.interval_ms)
          loop(agent, ctx, poll_seq + 1)
      end
    end
  end

  defp poll_once(agent, ctx, poll_seq) do
    case status_result(ctx, poll_seq) do
      {:ok, result} ->
        response = InterviewResponse.parent_response(result)
        text = InterviewResponse.text(response)
        meta = InterviewResponse.meta(response)
        status = status_value(meta)
        terminal? = terminal?(meta, status)

        LoopBindings.enqueue(agent, status_event(ctx, poll_seq, text, status, terminal?))

        if terminal?, do: :stop, else: :continue

      _error ->
        :continue
    end
  end

  defp status_result(ctx, poll_seq) do
    ctx.status_caller.(ctx.request_options, status_payload(ctx, poll_seq))
  rescue
    exception -> {:error, exception}
  end

  defp status_payload(ctx, poll_seq) do
    %{
      "jsonrpc" => "2.0",
      "id" => "child-status:" <> ctx.job_id <> ":" <> Integer.to_string(poll_seq),
      "method" => "tools/call",
      "params" => %{
        "name" => "ouroboros_job_status",
        "arguments" => %{"job_id" => ctx.job_id, "view" => "compact"}
      }
    }
  end

  defp status_value(meta) do
    case InterviewResponse.meta_value(meta, "status") do
      status when is_binary(status) and status != "" -> status
      _other -> nil
    end
  end

  defp terminal?(meta, status) do
    InterviewResponse.meta_value(meta, "is_terminal") == true or
      status in @terminal_statuses
  end

  # Shaped so `ChildSessionPaneEvent.from_lifecycle_event/1` registers/merges
  # the pane (type/parent_call_id/runtime_source/transport/child_id) and
  # `ChildSessionStreamEntry.entries_for_event/3` builds a stream entry from
  # `:params` via the strict seq/content path. The final terminal poll is
  # emitted as `:parent_call_result` so `ChildSessionPaneEvent.status_for/1`
  # flips the pane out of `:working`; non-terminal polls stay
  # `:parent_call_event` (always `:working`).
  defp status_event(ctx, poll_seq, text, status, terminal?) do
    content = status_content(ctx, poll_seq, text, status)
    event_type = if terminal?, do: :parent_call_result, else: :parent_call_event

    %{
      type: event_type,
      event_type: event_type,
      source: :terminal_runtime,
      runtime_source: "ouroboros",
      transport: :streamable_http,
      event_seq: poll_seq,
      child_id: ctx.child_id,
      session_id: ctx.child_id,
      parent_call_id: ctx.parent_call_id,
      external_ids: %{"childID" => ctx.child_id, "job_id" => ctx.job_id},
      status: status || "running",
      occurred_at_ms: System.system_time(:millisecond),
      params: %{
        "childID" => ctx.child_id,
        "job_id" => ctx.job_id,
        "seq" => poll_seq,
        "content" => content,
        "status" => status || "running"
      },
      payload: %{
        child_id: ctx.child_id,
        content: content,
        status: status || "running",
        seq: poll_seq
      }
    }
  end

  defp status_content(_ctx, _poll_seq, text, _status) when is_binary(text) and text != "",
    do: text

  defp status_content(ctx, poll_seq, _text, status) do
    "Ouroboros job " <>
      ctx.job_id <>
      " " <>
      (status || "running") <>
      " (poll " <> Integer.to_string(poll_seq) <> ")"
  end

  # `poll_seq` here is already `max_polls + 1`; the explicit content overrides
  # the generic `status_content/4` line so the pane shows why polling stopped.
  defp budget_exhausted_event(ctx, poll_seq) do
    content =
      "Ouroboros job " <> ctx.job_id <> " status polling stopped (budget exhausted)"

    ctx
    |> status_event(poll_seq, content, "poll_budget_exhausted", true)
  end
end
