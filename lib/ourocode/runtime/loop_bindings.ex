defmodule Ourocode.Runtime.LoopBindings do
  @moduledoc """
  Live wiring between the terminal prompt loop and the runtime MCP pipeline.

  The terminal `EventLoop` exposes pluggable seams (`on_prompt_input`,
  `poll_runtime_event`, `on_runtime_event`). Without bindings those default to
  no-ops, so an accepted `ooo` workflow prompt never actually dispatches and the
  MCP runtime never reaches the renderer.

  Design: the transport subscriber emits already-normalized lifecycle events.
  Those are queued in an ordered inbox that `poll_runtime_event` drains FIFO,
  exactly the source the loop expects. The loop owns journaling/handling of
  drained events (`EventLoop` already appends + dispatches them), and each
  transport additionally journals its own stream via its `journal_path`
  option, so no-loss is preserved without forcing the global pipeline
  sequence onto transport-local sequence numbers.

  This module is pure glue: it reuses existing pipeline modules, owns only a
  small ordered inbox plus live pane state, and never raises into the loop.
  """

  alias Ourocode.Runtime.McpDaemon
  alias Ourocode.Plugin.UserLevel.Entry, as: UserLevelEntry
  alias Ourocode.Plugin.UserLevel.Registry, as: UserLevelRegistry

  alias Ourocode.Runtime.{
    ChildSessionCancelDispatcher,
    LoopBindingEventFlow,
    LoopBindingAnswers,
    LoopBindingInterviewSession,
    LoopBindingParentCall,
    LoopBindingState,
    LoopBindingWorkflowDispatch,
    McpCapabilities
  }

  @max_interview_rounds 24
  @router_decision_timeout_ms 3_000
  @activity_keep 24

  @type t :: pid()

  @doc """
  Starts the bindings state agent linked to the caller.
  """
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(_opts \\ []) do
    Agent.start_link(&LoopBindingState.initial/0)
  end

  @doc """
  Stops any daemon owned by the bindings agent, then stops the state agent.
  """
  @spec stop(pid()) :: :ok
  def stop(agent) when is_pid(agent) do
    {handle, workers, waiter} =
      Agent.get(agent, fn state ->
        {
          Map.get(state, :mcp_daemon),
          Map.get(state, :workers, MapSet.new()),
          Map.get(state, :interview_waiter)
        }
      end)

    worker_refs = Map.new(workers, &{Process.monitor(&1), &1})
    Enum.each(workers, &send(&1, {:cancel_worker, :loop_bindings_stopped}))

    if is_pid(waiter) and Process.alive?(waiter),
      do: Process.exit(waiter, :shutdown)

    await_worker_guards(worker_refs, System.monotonic_time(:millisecond) + 1_000)
    McpDaemon.stop(handle)
    Agent.stop(agent)
    :ok
  rescue
    _exception -> :ok
  end

  @doc false
  @spec spawn_worker(pid(), (-> term())) :: pid()
  def spawn_worker(agent, fun) when is_pid(agent) and is_function(fun, 0) do
    guard =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        owner_ref = Process.monitor(agent)
        guard = self()

        worker =
          spawn_link(fn ->
            Process.put(:loop_bindings_guard, guard)
            result = fun.()
            send(guard, {:worker_finished, self(), result})
          end)

        await_worker(worker, owner_ref, agent, nil)

        Process.demonitor(owner_ref, [:flush])
        unregister_worker(agent, self())
      end)

    Agent.update(agent, fn state ->
      if Process.alive?(guard) do
        Map.update(state, :workers, MapSet.new([guard]), &MapSet.put(&1, guard))
      else
        state
      end
    end)

    guard
  end

  @doc false
  @spec register_worker_cleanup((-> term())) :: :ok
  def register_worker_cleanup(cleanup) when is_function(cleanup, 0) do
    case Process.get(:loop_bindings_guard) do
      guard when is_pid(guard) -> send(guard, {:register_cleanup, cleanup})
      _none -> :ok
    end

    :ok
  end

  defp await_worker(worker, owner_ref, agent, cleanup) do
    receive do
      {:register_cleanup, next_cleanup} when is_function(next_cleanup, 0) ->
        await_worker(worker, owner_ref, agent, next_cleanup)

      {:worker_finished, ^worker, _result} ->
        run_worker_cleanup(cleanup)

      {:EXIT, ^worker, _reason} ->
        run_worker_cleanup(cleanup)

      {:DOWN, ^owner_ref, :process, ^agent, _reason} ->
        stop_worker(worker)
        run_worker_cleanup(cleanup)

      {:cancel_worker, _reason} ->
        stop_worker(worker)
        run_worker_cleanup(cleanup)
    end
  end

  defp stop_worker(worker) do
    if Process.alive?(worker), do: Process.exit(worker, :shutdown)

    receive do
      {:EXIT, ^worker, _reason} -> :ok
    after
      1_000 -> :ok
    end
  end

  defp await_worker_guards(worker_refs, _deadline) when map_size(worker_refs) == 0, do: :ok

  defp await_worker_guards(worker_refs, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ref, :process, _pid, _reason} when is_map_key(worker_refs, ref) ->
        await_worker_guards(Map.delete(worker_refs, ref), deadline)
    after
      remaining ->
        Enum.each(Map.keys(worker_refs), &Process.demonitor(&1, [:flush]))
        :ok
    end
  end

  defp run_worker_cleanup(nil), do: :ok

  defp run_worker_cleanup(cleanup) do
    cleanup.()
    :ok
  rescue
    _exception -> :ok
  end

  defp unregister_worker(agent, worker) do
    if Process.alive?(agent) do
      Agent.update(agent, fn state ->
        Map.update(state, :workers, MapSet.new(), &MapSet.delete(&1, worker))
      end)
    end
  rescue
    _exception -> :ok
  end

  @doc """
  Builds the `EventLoop` option overrides for a healthy bootstrapped result.

  Returns `{:ok, pid, options}` when the result carries a usable runtime, or
  `:skip` for non-interactive/degraded results so existing behaviour (smoke,
  piped, no-runtime) stays byte-for-byte unchanged.
  """
  @spec attach(map()) :: {:ok, pid(), keyword()} | :skip
  def attach(%{runtime: %{services: %{event_pipeline: ep}} = runtime})
      when is_pid(ep) do
    case start_link() do
      {:ok, agent} ->
        {:ok, agent,
         [
           on_prompt_input: on_prompt_input_fun(agent, runtime),
           poll_runtime_event: poll_runtime_event_fun(agent),
           on_runtime_event: on_runtime_event_fun(agent),
           command_dispatch_options: command_dispatch_options()
         ]}

      _error ->
        :skip
    end
  end

  def attach(_result), do: :skip

  @doc """
  Snapshot of live pane + wonderTool state for the renderer.

  Shaped as `%{runtime: %{parent_panes:, child_panes:}}` so the existing
  `ShellRenderer.runtime_hierarchy/1` consumes it without changes.
  """
  @spec pane_snapshot(pid()) :: %{
          required(:runtime) => %{
            required(:parent_panes) => map(),
            required(:child_panes) => map()
          },
          required(:wonder_tool) => map() | nil,
          required(:interview) => map() | nil,
          required(:interview_session) => map() | nil,
          required(:paused) => boolean()
        }
  def pane_snapshot(agent) when is_pid(agent) do
    LoopBindingState.snapshot(agent, @activity_keep)
  end

  @doc """
  Clears an active wonderTool flow after it has been answered or cancelled.
  """
  @spec clear_wonder(pid()) :: :ok
  def clear_wonder(agent) when is_pid(agent) do
    LoopBindingAnswers.clear_wonder(agent)
  end

  @doc """
  Pauses the active interview/checkpoint so the user can talk to the main
  session, without discarding the question (Esc in the skill flow). The
  renderer dims the prompt block while paused; `resume_wonder/1` re-activates.
  """
  @spec pause_wonder(pid()) :: :ok
  def pause_wonder(agent) when is_pid(agent) do
    LoopBindingAnswers.pause_wonder(agent)
  end

  @spec resume_wonder(pid()) :: :ok
  def resume_wonder(agent) when is_pid(agent) do
    LoopBindingAnswers.resume_wonder(agent)
  end

  @doc """
  Records a free-text answer to the active interview question (PATH 2
  Socratic answer). Echoes an acknowledgement into the child stream so the
  exchange is visible and clears the pending question + pause flag. Relaying
  the answer onward to a live `ouroboros_interview` session reuses the
  transport seam and is server-dependent.
  """
  @spec answer_interview(pid(), String.t()) :: {:ok, String.t()} | {:error, :no_active_interview}
  def answer_interview(agent, text) when is_pid(agent) and is_binary(text) do
    LoopBindingAnswers.answer_interview(agent, text, &enqueue/2)
  end

  @doc """
  Stops the active interview immediately.

  This is separate from sending the text answer "cancel": the UI needs a real
  terminal state so stale wait spinners cannot reopen after the user cancels.
  """
  @spec cancel_interview(pid()) :: {:ok, String.t()} | {:error, :no_active_interview}
  def cancel_interview(agent) when is_pid(agent) do
    LoopBindingAnswers.cancel_interview(agent, &enqueue/2)
  end

  @doc """
  Captures one answer for the active wonderTool checkpoint.

  `selection` is a 1-based option index (or any `SelectionHandler` payload).
  On success the decision is captured, an acknowledgement is folded into the
  originating child stream so the answer is visibly closed, and the overlay is
  cleared. Routing the answer onward into a live MCP session reuses the same
  decision payload via the transport seam (best-effort, server-dependent).
  """
  @spec answer_wonder(pid(), term()) ::
          {:ok, map()} | {:error, :no_active_wonder | term()}
  def answer_wonder(agent, selection) when is_pid(agent) do
    LoopBindingAnswers.answer_wonder(agent, selection, &enqueue/2)
  end

  @doc """
  Cancels the active wonderTool checkpoint without selecting an option.

  This is distinct from Esc pause: cancel/decline is an explicit user answer
  that closes the checkpoint and, for interview ACP answer-choice prompts,
  unblocks the interview relay with a terminating answer.
  """
  @spec cancel_wonder(pid(), String.t()) :: {:ok, map()} | {:error, :no_active_wonder}
  def cancel_wonder(agent, reason \\ "cancel") when is_pid(agent) and is_binary(reason) do
    LoopBindingAnswers.cancel_wonder(agent, reason, &enqueue/2)
  end

  @doc """
  Ingests a normalized runtime event: folds it into live pane + wonderTool
  state immediately (so the renderer reflects streaming within its redraw
  cadence, independent of the prompt loop) and queues it for the loop poller
  (bookkeeping/journaling). Used by the transport relay and by tests.
  """
  @spec enqueue(pid(), map()) :: :ok
  def enqueue(agent, event) when is_pid(agent) and is_map(event) do
    LoopBindingEventFlow.enqueue(agent, event)
  end

  @doc """
  Absorbs an Ouroboros MCP capability/tool graph into the live merged command
  registry as dynamic-skill entries, so `/` discovery and the `ooo` routes are
  driven by what the server actually exposes rather than a hard-coded list.

  `tools` is a list of MCP tool descriptors (maps with at least a name). No-op
  for an empty/unknown graph so a missing server never breaks the loop.
  """
  @spec ingest_capabilities(map(), [map()]) :: {:ok, term()} | {:error, term()}
  def ingest_capabilities(runtime, tools), do: McpCapabilities.ingest(runtime, tools)

  # --- prompt input: dispatch every ooo workflow route ---------------------

  defp on_prompt_input_fun(agent, runtime) do
    fn task_request, input_event, _startup_result ->
      task_request = refine_user_level_route(task_request, runtime)

      LoopBindingWorkflowDispatch.handle_prompt(
        agent,
        runtime,
        task_request,
        input_event,
        workflow_dispatch_callbacks()
      )
    end
  end

  defp workflow_dispatch_callbacks do
    %{
      enqueue_failure: &enqueue_failure/3,
      run_interview_session: &run_interview_session/2,
      production_parent_call: &production_parent_call/3,
      mcp_url: &mcp_url/0
    }
  end

  # --- interview session loop (SKILL Path A, full agent) -------------------

  # `parent_call_fun` is `(payload -> {:ok, result} | {:error, term})` where
  # `result` is a `ParentCallResult` (or any map carrying `:response`). The
  # production fun streams transport events into the inbox AND returns the
  # final body; tests inject a deterministic stub. Public for that injection.
  @doc false
  @spec run_interview_session(pid(), keyword()) :: :ok
  def run_interview_session(agent, opts) when is_pid(agent) and is_list(opts) do
    LoopBindingInterviewSession.run(agent, opts,
      max_rounds: @max_interview_rounds,
      router_decision_timeout_ms: @router_decision_timeout_ms,
      callbacks: %{enqueue: &enqueue/2}
    )
  end

  # The production transport call: stream lifecycle events into the inbox (so
  # MCP telemetry panes update live) while returning the final body so the
  # session loop can parse the question/session_id. No `:journal_path` for the
  # same reason as the generic relay (see `project-route-event-seq` memory).
  defp production_parent_call(agent, runtime, parent_call_id) do
    LoopBindingParentCall.build(agent, runtime, parent_call_id, mcp_url())
  end

  defp enqueue_failure(agent, parent_call_id, reason) do
    enqueue(agent, Ourocode.Runtime.InterviewEvents.failure(parent_call_id, reason))

    :ok
  end

  # --- runtime event poll: drain the ordered inbox -------------------------

  defp poll_runtime_event_fun(agent) do
    LoopBindingEventFlow.poll_fun(agent)
  end

  # --- runtime event handling ----------------------------------------------

  # Pane/wonderTool folding happens at ingest time (see `enqueue/2`) so the
  # renderer reflects streaming on its own cadence. The loop still drains the
  # event for its bookkeeping/journaling path; nothing extra to do here.
  defp on_runtime_event_fun(agent) do
    LoopBindingEventFlow.runtime_event_fun(agent)
  end

  # --- helpers -------------------------------------------------------------

  @doc """
  Resolves the Ouroboros MCP base url used by all loop-binding transports.
  """
  @spec mcp_url() :: String.t()
  def mcp_url do
    System.get_env("OUROCODE_MCP_URL") || "http://127.0.0.1:4000/mcp"
  end

  # Production seam for the builtin `/interrupt` and `/cancel` slash commands.
  # `EventLoopState.build/3` stores these under `:command_dispatch_options`,
  # and `CommandChildControlCommands.dispatch_options/1` merges them with the
  # live focus state + pane model on every dispatch. Both actions deliver via
  # the same cancellation dispatcher because the live server only exposes
  # `ouroboros_cancel_job`/`ouroboros_cancel_execution` (no interrupt tool).
  defp command_dispatch_options do
    dispatcher = ChildSessionCancelDispatcher.build(mcp_url: mcp_url())

    %{
      child_session_interrupt_dispatcher: dispatcher,
      child_session_cancel_dispatcher: dispatcher
    }
  end

  defp refine_user_level_route(task_request, runtime) do
    if UserLevelEntry.candidate_input?(Map.get(task_request, :task_input)) do
      UserLevelEntry.refine(task_request, user_level_capabilities(runtime))
    else
      task_request
    end
  end

  defp user_level_capabilities(%{services: %{user_level_plugin_registry: pid}})
       when is_pid(pid) do
    pid
    |> UserLevelRegistry.list()
    |> Map.get(:capabilities, [])
  rescue
    _exception -> []
  end

  defp user_level_capabilities(%{user_level_capabilities: capabilities})
       when is_list(capabilities),
       do: capabilities

  defp user_level_capabilities(_runtime), do: []
end
