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

  alias Ourocode.Dashboard.{ChildSessionPanes, ParentMcpPane}
  alias Ourocode.MCP.ParentCallResult
  alias Ourocode.MCP.Transport.StreamableHTTP
  alias Ourocode.Model
  alias Ourocode.Model.Catalog
  alias Ourocode.Runtime.McpDaemon

  alias Ourocode.Runtime.{
    Application,
    Dispatcher,
    InterviewRouter,
    InterviewWorkflowInvocation
  }

  alias Ourocode.WonderTool.{DecisionFlow, InteractionDetector}

  @relay_grace_ms 2_000
  @max_interview_rounds 24
  @router_trace_keep 6
  @reasoning_keep 60
  @dialogue_keep 40

  @ouroboros_adapters %{
    {:ouroboros_workflow, :interview} => InterviewWorkflowInvocation,
    {:ouroboros, :interview} => InterviewWorkflowInvocation,
    :ouroboros_interview => InterviewWorkflowInvocation
  }

  @type t :: pid()

  @doc """
  Starts the bindings state agent linked to the caller.
  """
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(_opts \\ []) do
    Agent.start_link(fn ->
      %{
        inbox: :queue.new(),
        parent: ParentMcpPane.new(),
        child: ChildSessionPanes.new(),
        wonder: nil,
        interview: nil,
        interview_session: nil,
        interview_waiter: nil,
        mcp_daemon: nil,
        mcp_llm_backend: nil,
        paused: false
      }
    end)
  end

  @doc """
  Stops any daemon owned by the bindings agent, then stops the state agent.
  """
  @spec stop(pid()) :: :ok
  def stop(agent) when is_pid(agent) do
    handle = Agent.get(agent, &Map.get(&1, :mcp_daemon))
    McpDaemon.stop(handle)
    Agent.stop(agent)
    :ok
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
           on_runtime_event: on_runtime_event_fun(agent)
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
    Agent.get(agent, fn state ->
      %{
        runtime: %{parent_panes: state.parent, child_panes: state.child},
        wonder_tool: state.wonder,
        interview: state.interview,
        interview_session: state.interview_session,
        paused: state.paused
      }
    end)
  end

  @doc """
  Clears an active wonderTool flow after it has been answered or cancelled.
  """
  @spec clear_wonder(pid()) :: :ok
  def clear_wonder(agent) when is_pid(agent) do
    Agent.update(agent, &Map.put(&1, :wonder, nil))
  end

  @doc """
  Pauses the active interview/checkpoint so the user can talk to the main
  session, without discarding the question (Esc in the skill flow). The
  renderer dims the prompt block while paused; `resume_wonder/1` re-activates.
  """
  @spec pause_wonder(pid()) :: :ok
  def pause_wonder(agent) when is_pid(agent) do
    Agent.update(agent, &Map.put(&1, :paused, true))
  end

  @spec resume_wonder(pid()) :: :ok
  def resume_wonder(agent) when is_pid(agent) do
    Agent.update(agent, &Map.put(&1, :paused, false))
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
    case Agent.get(agent, &{&1.interview, Map.get(&1, :interview_waiter)}) do
      {%{} = interview, waiter} ->
        enqueue(agent, interview_ack_event(interview, text))

        Agent.update(agent, fn state ->
          %{
            state
            | interview: Map.put(interview, :answered, text),
              interview_waiter: nil,
              paused: false
          }
        end)

        # Hand the answer to a relay loop that is blocked waiting on an
        # ASK_USER routing decision (SKILL PATH 2). Without a waiter the
        # answer is still recorded + acked (server-relayed turns reuse the
        # transport seam), so this stays backward compatible.
        if is_pid(waiter), do: send(waiter, {:interview_answer, text})

        {:ok, text}

      {_none, _waiter} ->
        {:error, :no_active_interview}
    end
  end

  defp interview_ack_event(interview, text) do
    %{
      type: :child_event,
      event_type: :child_event,
      source: :interview,
      transport: :streamable_http,
      parent_call_id: Map.get(interview, :parent_call_id),
      child_id: Map.get(interview, :child_id),
      runtime_source: "ouroboros",
      occurred_at_ms: System.system_time(:millisecond),
      payload: %{kind: :interview_answer, token: "you: " <> text}
    }
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
    case Agent.get(agent, &{&1.wonder, Map.get(&1, :interview_waiter)}) do
      {%{request: request} = detection, waiter} ->
        case capture_all(request, selection) do
          {:ok, decisions} ->
            combined = combine_decisions(decisions)
            enqueue(agent, wonder_ack_event(detection, combined))
            clear_wonder(agent)

            # When the wonder was a synthesized interview ASK_USER checkpoint,
            # hand the chosen answer back to the blocked relay loop so the
            # interview proceeds (mirrors answer_interview/2's handoff). For a
            # multi-question server checkpoint there is no relay waiter — the
            # ack alone closes it.
            if is_pid(waiter) do
              Agent.update(agent, &Map.put(&1, :interview_waiter, nil))
              send(waiter, {:interview_answer, combined.handback})
            end

            {:ok, combined.result}

          {:error, _reason} = error ->
            error
        end

      {_no_active, _waiter} ->
        {:error, :no_active_wonder}
    end
  end

  @doc """
  Cancels the active wonderTool checkpoint without selecting an option.

  This is distinct from Esc pause: cancel/decline is an explicit user answer
  that closes the checkpoint and, for synthesized interview ASK_USER prompts,
  unblocks the interview relay with a terminating answer.
  """
  @spec cancel_wonder(pid(), String.t()) :: {:ok, map()} | {:error, :no_active_wonder}
  def cancel_wonder(agent, reason \\ "cancel") when is_pid(agent) and is_binary(reason) do
    case Agent.get(agent, &{&1.wonder, Map.get(&1, :interview_waiter)}) do
      {%{} = detection, waiter} ->
        cancelled = %{
          cancelled: true,
          reason: cancel_reason(reason),
          question_id: wonder_question_id(detection)
        }

        enqueue(agent, wonder_cancel_event(detection, cancelled))

        Agent.update(agent, fn state ->
          %{
            state
            | wonder: nil,
              interview_waiter: nil,
              paused: false
          }
        end)

        if is_pid(waiter), do: send(waiter, {:interview_answer, "cancel"})

        {:ok, cancelled}

      {_no_active, _waiter} ->
        {:error, :no_active_wonder}
    end
  end

  # A bare index/string/map answers the single active question (back-compat,
  # also the always-1-question interview path). A list answers each question
  # in `request.questions` order — a multi-question server wonderTool — by
  # capturing every selection with its own question_id.
  defp capture_all(request, selections) when is_list(selections) do
    questions = Map.get(request, :questions, [])

    if single_multi_select_question?(questions) do
      capture_all(request, %{"selectedOptions" => selections})
    else
      selections
      |> Enum.zip(questions)
      |> Enum.reduce_while({:ok, []}, fn {sel, q}, {:ok, acc} ->
        case DecisionFlow.capture(request, sel, question_id: Map.get(q, :id)) do
          {:ok, decision} -> {:cont, {:ok, [decision | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, []} -> {:error, :selection_required}
        {:ok, decisions} -> {:ok, Enum.reverse(decisions)}
        error -> error
      end
    end
  end

  defp capture_all(request, selection) do
    case DecisionFlow.capture(request, selection) do
      {:ok, decision} -> {:ok, [decision]}
      {:error, _reason} -> capture_free_text(request, selection)
    end
  end

  defp capture_free_text(request, selection) do
    with text when is_binary(text) and text != "" <- free_text_selection(selection),
         %{} = question <- free_text_question(request, selection) do
      {:ok, [free_text_decision(request, question, text)]}
    else
      _other -> {:error, :selection_required}
    end
  end

  defp free_text_selection(selection) when is_map(selection) do
    selection
    |> first_present([
      "freeText",
      "free_text",
      "otherText",
      "other_text",
      :freeText,
      :free_text,
      :otherText,
      :other_text
    ])
    |> case do
      text when is_binary(text) -> String.trim(text)
      _other -> nil
    end
  end

  defp free_text_selection(_selection), do: nil

  defp free_text_question(request, selection) do
    questions = Map.get(request, :questions, [])
    requested_id = free_text_question_id(selection)

    cond do
      is_binary(requested_id) and requested_id != "" ->
        Enum.find(questions, &question_id_match?(&1, requested_id)) || List.first(questions)

      true ->
        List.first(questions)
    end
  end

  defp free_text_question_id(selection) when is_map(selection) do
    selection
    |> first_present([
      "questionId",
      "question_id",
      :questionId,
      :question_id
    ])
    |> case do
      id when is_binary(id) -> String.trim(id)
      _other -> nil
    end
  end

  defp free_text_question_id(_selection), do: nil

  defp question_id_match?(%{} = question, id) do
    (Map.get(question, :id) || Map.get(question, "id")) == id
  end

  defp question_id_match?(_question, _id), do: false

  defp first_present(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp free_text_decision(request, question, text) do
    %{
      type: :wonder_decision,
      question_id: Map.get(question, :id) || Map.get(question, "id") || "free_answer",
      question_kind: Map.get(question, :kind) || Map.get(question, "kind"),
      selected_index: 0,
      selected_label: text,
      selected_description: "Free answer",
      selected_option: %{label: text, description: "Free answer", free_text?: true},
      free_text: text,
      selected_at_ms: System.system_time(:millisecond),
      request_id: Map.get(request, :request_id),
      child_id: Map.get(request, :child_id),
      parent_call_id: Map.get(request, :parent_call_id),
      external_ids: Map.get(request, :external_ids)
    }
  end

  defp single_multi_select_question?([question]) do
    Map.get(question, :multi_select?, false) == true
  end

  defp single_multi_select_question?(_questions), do: false

  # One decision keeps the legacy shape exactly (the interview waiter expects a
  # single label; loop_bindings_test asserts `selected_label`). Many decisions
  # hand back one line per question and surface every decision under
  # `:decisions` while still carrying a joined `:selected_label` for callers
  # that only log a label.
  defp combine_decisions([decision]) do
    %{result: decision, handback: decision.selected_label, token: decision.selected_label}
  end

  defp combine_decisions(decisions) do
    label = Enum.map_join(decisions, "; ", & &1.selected_label)

    handback =
      Enum.map_join(decisions, "\n", fn d ->
        "#{d.question_id}: #{d.selected_label}"
      end)

    {first, _rest} = List.pop_at(decisions, 0)

    result =
      first
      |> Map.put(:decisions, decisions)
      |> Map.put(:selected_label, label)

    %{result: result, handback: handback, token: label}
  end

  defp wonder_ack_event(detection, %{result: decision, token: token}) do
    %{
      type: :child_event,
      event_type: :child_event,
      source: :wonder_tool,
      transport: :streamable_http,
      parent_call_id: Map.get(detection, :parent_call_id),
      child_id: Map.get(detection, :child_id),
      runtime_source: "ouroboros",
      occurred_at_ms: System.system_time(:millisecond),
      payload: %{
        kind: :wonder_tool_answer,
        question_id: decision.question_id,
        token: "answered: " <> token
      }
    }
  end

  defp wonder_cancel_event(detection, cancelled) do
    %{
      type: :child_event,
      event_type: :child_event,
      source: :wonder_tool,
      transport: :streamable_http,
      parent_call_id: Map.get(detection, :parent_call_id),
      child_id: Map.get(detection, :child_id),
      runtime_source: "ouroboros",
      occurred_at_ms: System.system_time(:millisecond),
      payload: %{
        kind: :wonder_tool_cancelled,
        question_id: cancelled.question_id,
        token: "declined: " <> cancelled.reason
      }
    }
  end

  defp cancel_reason(reason) do
    reason
    |> String.trim()
    |> case do
      "" -> "cancel"
      text -> text
    end
  end

  defp wonder_question_id(%{request: %{questions: [%{} = question | _rest]}}) do
    Map.get(question, :id) || Map.get(question, "id")
  end

  defp wonder_question_id(_detection), do: nil

  @doc """
  Ingests a normalized runtime event: folds it into live pane + wonderTool
  state immediately (so the renderer reflects streaming within its redraw
  cadence, independent of the prompt loop) and queues it for the loop poller
  (bookkeeping/journaling). Used by the transport relay and by tests.
  """
  @spec enqueue(pid(), map()) :: :ok
  def enqueue(agent, event) when is_pid(agent) and is_map(event) do
    Agent.update(agent, fn state ->
      state
      |> Map.update!(:inbox, &:queue.in(event, &1))
      |> fold_event(event)
    end)
  end

  @doc """
  Absorbs an Ouroboros MCP capability/tool graph into the live merged command
  registry as dynamic-skill entries, so `/` discovery and the `ooo` routes are
  driven by what the server actually exposes rather than a hard-coded list.

  `tools` is a list of MCP tool descriptors (maps with at least a name). No-op
  for an empty/unknown graph so a missing server never breaks the loop.
  """
  @spec ingest_capabilities(map(), [map()]) :: {:ok, term()} | {:error, term()}
  def ingest_capabilities(runtime, tools) when is_list(tools) do
    skills =
      tools
      |> Enum.map(&capability_skill/1)
      |> Enum.reject(&is_nil/1)

    case skills do
      [] ->
        {:ok, :no_capabilities}

      skills ->
        Application.discover_dynamic_skills(runtime, skills,
          reason: :mcp_capability_discovery,
          discovered_from: "ouroboros-mcp",
          source_id: "ouroboros"
        )
    end
  rescue
    exception -> {:error, {:capability_ingest_failed, Exception.message(exception)}}
  end

  def ingest_capabilities(_runtime, _tools), do: {:ok, :no_capabilities}

  defp capability_skill(tool) when is_map(tool) do
    name = tool["name"] || tool[:name]

    if is_binary(name) and name != "" do
      description = tool["description"] || tool[:description] || name

      %{
        "name" => name,
        "id" => name,
        "description" => to_string(description),
        "mcp_tool" => name,
        "source_id" => "ouroboros",
        "discovered_from" => "ouroboros-mcp"
      }
    end
  end

  defp capability_skill(_tool), do: nil

  defp maybe_ingest_capabilities(runtime, event) do
    case capability_tools(event) do
      [] -> :ok
      tools -> ingest_capabilities(runtime, tools)
    end
  rescue
    _exception -> :ok
  end

  defp capability_tools(event) when is_map(event) do
    event
    |> Map.get(:payload, event)
    |> dig_tools()
  end

  defp capability_tools(_event), do: []

  defp dig_tools(%{} = map) do
    cond do
      is_list(map["tools"]) -> map["tools"]
      is_list(map[:tools]) -> map[:tools]
      is_map(map["result"]) -> dig_tools(map["result"])
      is_map(map[:result]) -> dig_tools(map[:result])
      true -> []
    end
  end

  defp dig_tools(_other), do: []

  # --- prompt input: dispatch every ooo workflow route ---------------------

  defp on_prompt_input_fun(agent, runtime) do
    fn task_request, input_event, _startup_result ->
      if ouroboros_route?(task_request) do
        dispatch_workflow(agent, runtime, task_request, input_event)
      end

      :ok
    end
  end

  defp ouroboros_route?(%{routing_decision: %{execution_route: :ouroboros_workflow}}), do: true
  defp ouroboros_route?(_task_request), do: false

  defp dispatch_workflow(agent, runtime, task_request, input_event) do
    parent_call_id = "parent-" <> to_string(task_request.id)
    model = input_event_model(input_event) || Catalog.default()
    {:ok, mcp_url} = ensure_mcp_daemon(agent, model)
    invoker = transport_invoker(agent, runtime, parent_call_id, model)

    Dispatcher.dispatch(task_request,
      adapters: @ouroboros_adapters,
      context: %{
        request_id: "req-" <> to_string(task_request.id),
        parent_call_id: parent_call_id,
        streamable_http_url: mcp_url,
        cwd: File.cwd!(),
        mcp_invoker: invoker
      }
    )
    |> case do
      {:ok, _invocation} -> :ok
      {:error, reason} -> enqueue_failure(agent, parent_call_id, {:dispatch_failed, reason})
    end
  rescue
    exception ->
      enqueue_failure(
        agent,
        "parent-" <> to_string(task_request.id),
        {:dispatch_exception, Exception.message(exception)}
      )
  end

  # The invoker returns immediately; the transport call runs in a relay process
  # so the prompt loop never blocks on the network and streamed events reach
  # the inbox as they arrive.
  defp transport_invoker(agent, runtime, parent_call_id, model) do
    fn payload, _transport_options ->
      start_relay(agent, runtime, parent_call_id, payload, model)
      {:ok, %{parent_call_id: parent_call_id}}
    end
  end

  # Interview calls drive the SKILL Path A loop (parse question → route →
  # answer back → repeat until seed-ready). Every other ouroboros workflow
  # keeps the byte-for-byte single-shot relay.
  defp start_relay(agent, runtime, parent_call_id, payload, model) do
    if interview_payload?(payload) do
      spawn(fn ->
        run_interview_session(agent,
          parent_call_id: parent_call_id,
          initial_payload: payload,
          parent_call_fun: production_parent_call(agent, runtime, parent_call_id),
          model: model,
          project_dir: project_dir(runtime)
        )
      end)
    else
      spawn(fn -> relay_loop(agent, runtime, parent_call_id, payload) end)
    end
  end

  defp interview_payload?(payload) when is_map(payload) do
    get_in(payload, ["params", "name"]) == "ouroboros_interview"
  end

  defp interview_payload?(_payload), do: false

  defp input_event_model(%{active_model: %Model{} = model}), do: model
  defp input_event_model(%{"active_model" => %Model{} = model}), do: model
  defp input_event_model(_event), do: nil

  defp ensure_mcp_daemon(agent, %Model{} = model) do
    requested_backend = mcp_llm_backend(model)

    Agent.get_and_update(agent, fn state ->
      handle = Map.get(state, :mcp_daemon)
      current_backend = Map.get(state, :mcp_llm_backend)

      if reuse_mcp_daemon?(handle, current_backend, requested_backend) do
        {{:ok, Map.get(handle, :url, mcp_url())}, state}
      else
        McpDaemon.stop(handle)
        {:ok, new_handle} = McpDaemon.maybe_start(llm_backend: requested_backend)

        next_state =
          state
          |> Map.put(:mcp_daemon, new_handle)
          |> Map.put(:mcp_llm_backend, requested_backend)

        {{:ok, Map.get(new_handle, :url, mcp_url())}, next_state}
      end
    end)
  end

  defp ensure_mcp_daemon(agent, _model), do: ensure_mcp_daemon(agent, Catalog.default())

  defp reuse_mcp_daemon?(nil, _current_backend, _requested_backend), do: false
  defp reuse_mcp_daemon?(%{mode: :external}, _current_backend, _requested_backend), do: true

  defp reuse_mcp_daemon?(_handle, current_backend, requested_backend),
    do: current_backend == requested_backend

  defp mcp_llm_backend(%Model{id: id}) when id in [:codex, :codex_cli], do: "codex"
  defp mcp_llm_backend(%Model{id: :claude}), do: "claude_code"
  defp mcp_llm_backend(_model), do: System.get_env("OUROCODE_MCP_LLM_BACKEND")

  defp project_dir(runtime) when is_map(runtime),
    do: Map.get(runtime, :project_dir) || File.cwd!()

  defp project_dir(_runtime), do: File.cwd!()

  defp relay_loop(agent, runtime, parent_call_id, payload) do
    relay = self()

    spawn(fn ->
      # No `:journal_path` — the transport's optional self-journaling stamps
      # a transport-local event_seq (1,2,..) and `Journal.append!` enforces a
      # contiguous sequence, which raises `{:event_seq_gap, n, 1}` and kills
      # the relay. Events still reach panes via the `subscriber` relay; the
      # seed's no-loss journaling is the runtime pipeline's concern, not the
      # transport's, in this wiring. See the `project-route-event-seq` memory.
      result =
        StreamableHTTP.execute_parent_call(
          [
            url: mcp_url(),
            parent_call_id: parent_call_id,
            runtime_source: "ouroboros",
            subscriber: relay,
            mcp_session: true,
            timeout: 30_000
          ],
          payload
        )

      send(relay, {:relay_worker_done, result})
    end)

    relay_drain(agent, runtime, parent_call_id)
  end

  defp relay_drain(agent, runtime, parent_call_id) do
    receive do
      {:ourocode_event, event} ->
        enqueue(agent, event)
        maybe_ingest_capabilities(runtime, event)
        relay_drain(agent, runtime, parent_call_id)

      {:relay_worker_done, {:error, reason}} ->
        enqueue_failure(agent, parent_call_id, {:transport_failed, reason})
        relay_flush(agent)

      {:relay_worker_done, _ok} ->
        relay_flush(agent)
    end
  end

  defp relay_flush(agent) do
    receive do
      {:ourocode_event, event} ->
        enqueue(agent, event)
        relay_flush(agent)
    after
      @relay_grace_ms -> :ok
    end
  end

  # --- interview session loop (SKILL Path A, full agent) -------------------

  # `parent_call_fun` is `(payload -> {:ok, result} | {:error, term})` where
  # `result` is a `ParentCallResult` (or any map carrying `:response`). The
  # production fun streams transport events into the inbox AND returns the
  # final body; tests inject a deterministic stub. Public for that injection.
  @doc false
  @spec run_interview_session(pid(), keyword()) :: :ok
  def run_interview_session(agent, opts) when is_pid(agent) and is_list(opts) do
    parent_call_id = Keyword.fetch!(opts, :parent_call_id)
    payload = Keyword.fetch!(opts, :initial_payload)
    pcf = Keyword.fetch!(opts, :parent_call_fun)
    model = Keyword.fetch!(opts, :model)
    project_dir = Keyword.get(opts, :project_dir) || File.cwd!()
    max_rounds = Keyword.get(opts, :max_rounds, @max_interview_rounds)

    interview_round(agent, %{
      pcf: pcf,
      model: model,
      project_dir: project_dir,
      parent_call_id: parent_call_id,
      payload: payload,
      round: 1,
      max_rounds: max_rounds,
      streak: 0,
      session_id: nil
    })
  rescue
    exception ->
      enqueue_failure(
        agent,
        Keyword.get(opts, :parent_call_id, "parent-interview"),
        {:interview_loop_exception, Exception.message(exception)}
      )

      :ok
  end

  defp interview_round(agent, %{round: round, max_rounds: max, parent_call_id: pcid})
       when round > max do
    enqueue_complete(agent, pcid, :max_rounds)
    :ok
  end

  defp interview_round(agent, st) do
    mark_interview_waiting(agent, st)

    case st.pcf.(st.payload) do
      {:ok, result} ->
        response = parent_response(result)
        text = response_text(response)
        meta = response_meta(response)
        session_id = extract_session_id(text, meta) || st.session_id

        # Classify by the response TEXT, not `meta`/`isError`. Verified
        # against the live Ouroboros server: the FastMCP adapter returns
        # only `text_content` — `meta` and even server-side recoverable
        # failures (`is_error=True`) are dropped, so a question-generation
        # failure arrives as `isError:false` + a "Question generation
        # failed: …" body. Routing that text as a question is exactly the
        # "interview not progressing" symptom.
        case classify_response(text) do
          {:server_error, message} ->
            enqueue_server_error(agent, st.parent_call_id, message, session_id)
            :ok

          :complete ->
            merge_interview(agent, st.parent_call_id, text, meta, session_id)
            enqueue_complete(agent, st.parent_call_id, :seed_ready)
            :ok

          {:question, question} ->
            enqueue(agent, interview_question_event(st.parent_call_id, text, meta))
            merge_interview(agent, st.parent_call_id, text, meta, session_id)
            push_dialogue(agent, :mcp, mcp_turn_text(text))

            if is_nil(session_id) do
              enqueue_failure(agent, st.parent_call_id, :interview_session_id_missing)
              :ok
            else
              route_question(agent, %{st | session_id: session_id}, question)
            end
        end

      {:error, reason} ->
        enqueue_failure(agent, st.parent_call_id, {:transport_failed, reason})
        :ok
    end
  end

  # The interview wire is plain text (no meta). Anchor on the documented
  # Ouroboros phrasings: completion (`Interview completed` /
  # `Ready for Seed generation`, plus the SKILL `ooo seed` next-step),
  # recoverable question-generation failure (`Question generation failed`,
  # delivered as a success body), and otherwise a real question.
  defp classify_response(text) when is_binary(text) do
    cond do
      String.trim(text) == "" ->
        {:server_error, "empty response from the MCP question generator"}

      Regex.match?(
        ~r/Interview completed|Ready for Seed generation|📍\s*Next:\s*ooo seed|\booo seed\b|seed-ready/i,
        text
      ) ->
        :complete

      Regex.match?(
        ~r/Question generation failed|question generation failed after retries|MCP is having trouble/i,
        text
      ) ->
        {:server_error, server_failure_message(text)}

      true ->
        {:question, question_from(text)}
    end
  end

  defp classify_response(_text),
    do: {:server_error, "empty response from the MCP question generator"}

  # The failure reason is everything up to the trailing "Session ID:" /
  # "Resume with:" boilerplate, flattened and capped for the panel.
  defp server_failure_message(text) do
    text
    |> String.split(~r/\s*\.?\s*Session ID:|Resume with:/, parts: 2)
    |> List.first()
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 240)
  end

  # A server-side question-generation failure: surface it clearly (reason +
  # session + resume hint) instead of presenting the error body as a
  # question, and stop the loop. `enqueue_failure` is reused for the parent
  # pane (non-conflicting); the interview state carries the human-readable
  # status + session so the right reasoning column explains *why* it is not
  # progressing — the MCP-internal visibility the operator asked for.
  defp enqueue_server_error(agent, parent_call_id, message, session_id) do
    status = "MCP question generator unavailable: " <> message

    enqueue(agent, %{
      type: :child_event,
      event_type: :child_event,
      source: :interview,
      transport: :streamable_http,
      parent_call_id: parent_call_id,
      runtime_source: "ouroboros",
      occurred_at_ms: System.system_time(:millisecond),
      payload: %{
        :kind => :interview_error,
        :token => status <> resume_hint(session_id),
        "meta" => %{}
      }
    })

    Agent.update(agent, fn state ->
      iv =
        (state.interview || %{})
        |> Map.put(:status, status)
        |> maybe_put(:session_id, session_id)
        |> Map.put(:resumable, not is_nil(session_id))
        |> Map.delete(:answered)

      %{state | interview: iv, interview_waiter: nil}
    end)

    push_dialogue(agent, :mcp, status <> resume_hint(session_id))

    enqueue_failure(
      agent,
      parent_call_id,
      {:mcp_question_generator_unavailable, message, session_id}
    )

    :ok
  end

  defp resume_hint(nil), do: ""
  defp resume_hint(session_id), do: "  (session=#{session_id}, resume available)"

  defp route_question(agent, st, question) do
    question = clean_markdown(question)
    ctx = %{project_dir: st.project_dir, streak: st.streak}
    on_trace = fn line -> push_router_trace(agent, line) end
    on_reason = fn chunk -> push_reasoning(agent, chunk) end

    case InterviewRouter.decide(question, ctx, st.model,
           on_trace: on_trace,
           on_reason: on_reason
         ) do
      {:answer, payload_text, source} ->
        if leaked_router_prompt?(payload_text) do
          push_router_trace(agent, "router: discarded echoed prompt and asked user")
          push_dialogue(agent, :main, "→ asking you: " <> clean_markdown(question))
          enqueue(agent, ask_user_wonder_event(st.parent_call_id, st.round, question, []))

          case await_user_answer(agent, st.parent_call_id, question) do
            {:done, text} ->
              push_dialogue(agent, :user, text)
              enqueue_complete(agent, st.parent_call_id, :user_done)
              :ok

            {:answer, user_text} ->
              push_dialogue(agent, :user, user_text)
              followup(agent, st, ensure_user_prefix(user_text), 0)
          end
        else
          push_dialogue(agent, :main, ensure_answer_prefix(payload_text, source))
          followup(agent, st, payload_text, streak_after(st.streak, source))
        end

      {:ask_user, prompt, options} ->
        # SKILL PATH 2: present as a wonderTool checkpoint (model-suggested
        # options, padded to the wonderTool 2-option minimum). The user may
        # pick an option (→ answer_wonder) or free-type (→ answer_interview);
        # both hand the text back to this blocked relay via interview_waiter.
        push_dialogue(agent, :main, "→ asking you: " <> clean_markdown(prompt))
        enqueue(agent, ask_user_wonder_event(st.parent_call_id, st.round, prompt, options))

        case await_user_answer(agent, st.parent_call_id, prompt) do
          {:done, text} ->
            push_dialogue(agent, :user, text)
            enqueue_complete(agent, st.parent_call_id, :user_done)
            :ok

          {:answer, user_text} ->
            push_dialogue(agent, :user, user_text)
            followup(agent, st, ensure_user_prefix(user_text), 0)
        end

      {:error, reason} ->
        enqueue_failure(agent, st.parent_call_id, {:router_failed, reason})
        :ok
    end
  end

  @generic_ask_options [
    %{
      "label" => "Answer in my own words",
      "description" => "Type a free-text answer instead of picking"
    },
    %{"label" => "Not sure — skip for now", "description" => "I can't decide this yet"}
  ]

  defp ask_user_wonder_event(parent_call_id, round, prompt, options) do
    %{
      type: :child_event,
      event_type: :child_event,
      source: :wonder_tool,
      transport: :streamable_http,
      parent_call_id: parent_call_id,
      runtime_source: "ouroboros",
      occurred_at_ms: System.system_time(:millisecond),
      payload: %{
        "tool" => "wonderTool",
        "request_id" => "#{parent_call_id}-ask-#{round}",
        "parent_call_id" => parent_call_id,
        "questions" => [
          %{
            "id" => "interview",
            "header" => "Interview",
            "question" => clean_markdown(prompt),
            "options" => wonder_options(options)
          }
        ]
      }
    }
  end

  # wonderTool requires at least 2 options; the model may give fewer. Keep the
  # model's options first, then pad with generic affordances (free-type / skip)
  # so the checkpoint always renders. The baseline schema supports 2-4 choices.
  defp wonder_options(model_options) do
    mapped =
      model_options
      |> Enum.take(4)
      |> Enum.map(fn %{label: l, description: d} ->
        %{"label" => to_string(l), "description" => to_string(d)}
      end)

    (mapped ++ @generic_ask_options)
    |> Enum.uniq_by(& &1["label"])
    |> Enum.take(max(2, length(mapped)))
  end

  defp followup(agent, st, answer_text, new_streak) do
    case InterviewWorkflowInvocation.build_followup_request_payload(
           st.session_id,
           answer_text,
           request_id: st.parent_call_id <> "-r" <> Integer.to_string(st.round)
         ) do
      {:ok, payload} ->
        interview_round(agent, %{
          st
          | payload: payload,
            round: st.round + 1,
            streak: new_streak
        })

      {:error, reason} ->
        enqueue_failure(agent, st.parent_call_id, {:followup_payload_failed, reason})
        :ok
    end
  end

  defp await_user_answer(agent, parent_call_id, prompt) do
    me = self()

    Agent.update(agent, fn state ->
      prev = state.interview || %{}

      iv =
        prev
        |> Map.merge(%{
          question: clean_markdown(prompt),
          parent_call_id: parent_call_id || prev[:parent_call_id],
          waiting: false,
          status: "waiting for your answer"
        })
        |> Map.delete(:answered)

      %{state | interview: iv, interview_waiter: me, paused: false}
    end)

    receive do
      {:interview_answer, text} ->
        if user_terminated?(text), do: {:done, text}, else: {:answer, text}
    end
  end

  defp user_terminated?(text) when is_binary(text) do
    String.downcase(String.trim(text)) in ["done", "cancel", "stop", "/cancel"]
  end

  defp ensure_user_prefix(text) do
    trimmed = String.trim(text)
    if String.starts_with?(trimmed, "[from-"), do: trimmed, else: "[from-user] " <> trimmed
  end

  defp streak_after(_streak, :user), do: 0
  defp streak_after(streak, _source), do: streak + 1

  # The production transport call: stream lifecycle events into the inbox (so
  # MCP telemetry panes update live) while returning the final body so the
  # session loop can parse the question/session_id. No `:journal_path` for the
  # same reason as the generic relay (see `project-route-event-seq` memory).
  defp production_parent_call(agent, runtime, parent_call_id) do
    fn payload ->
      relay = self()

      spawn(fn ->
        result =
          StreamableHTTP.execute_parent_call(
            [
              url: mcp_url(),
              parent_call_id: parent_call_id,
              runtime_source: "ouroboros",
              subscriber: relay,
              mcp_session: true,
              timeout: 30_000
            ],
            payload
          )

        send(relay, {:relay_worker_done, result})
      end)

      drain_until_done(agent, runtime)
    end
  end

  defp drain_until_done(agent, runtime) do
    receive do
      {:ourocode_event, event} ->
        enqueue(agent, event)
        maybe_ingest_capabilities(runtime, event)
        drain_until_done(agent, runtime)

      {:relay_worker_done, result} ->
        relay_flush(agent)
        result
    end
  end

  # --- interview response parsing -----------------------------------------

  defp parent_response(%ParentCallResult{response: response}) when is_map(response),
    do: response

  defp parent_response(%{response: response}) when is_map(response), do: response
  defp parent_response(%{"response" => response}) when is_map(response), do: response
  defp parent_response(_result), do: %{}

  defp response_text(%{"result" => %{"content" => content}}) when is_list(content) do
    content
    |> Enum.map(fn part -> (is_map(part) && (part["text"] || part[:text])) || nil end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp response_text(%{"result" => %{"content" => text}}) when is_binary(text), do: text
  defp response_text(_response), do: ""

  defp response_meta(%{"result" => %{"meta" => meta}}) when is_map(meta), do: meta

  defp response_meta(%{"result" => %{"structuredContent" => %{"meta" => meta}}})
       when is_map(meta),
       do: meta

  defp response_meta(response) do
    response
    |> response_text()
    |> decode_text_meta()
  end

  # Ouroboros writes the session id as `Session ID: <id>` (start),
  # `session_id="<id>"` (resume hint), or bare `Session <id>` (resume). The
  # `meta` fallback stays for transports/tests that still carry it.
  @session_id_re ~r/(?:session[_\s]?id)\s*[=:]\s*"?([A-Za-z0-9_\-\.]+)"?|(?<![A-Za-z])Session\s+([A-Za-z][\w\-\.]+)/i

  defp extract_session_id(text, meta) do
    case meta_value(meta, "session_id") do
      id when is_binary(id) and id != "" ->
        id

      _none ->
        case Regex.run(@session_id_re, text || "") do
          [_, id] when is_binary(id) and id != "" -> id
          [_, "", id] when is_binary(id) and id != "" -> id
          _no_match -> nil
        end
    end
  end

  defp question_from(text) do
    case parse_ambiguity(text) do
      {:ok, _score, question} -> clean_markdown(question)
      :none -> clean_markdown(String.trim(text || ""))
    end
  end

  # --- interview state helpers --------------------------------------------

  defp mark_interview_waiting(agent, st) do
    Agent.update(agent, fn state ->
      prev = state.interview || %{}

      iv =
        prev
        |> Map.merge(%{
          parent_call_id: st.parent_call_id || prev[:parent_call_id],
          question: Map.get(prev, :question, ""),
          waiting: true,
          status: waiting_status(st.round)
        })
        |> Map.delete(:answered)

      session = %{
        parent_call_id: st.parent_call_id,
        label: "ooo interview",
        status: waiting_status(st.round),
        round: st.round
      }

      %{state | interview: iv, interview_session: session, paused: false}
    end)
  end

  defp waiting_status(1), do: "waiting for MCP interview question"
  defp waiting_status(_round), do: "waiting for MCP follow-up question"

  defp interview_question_event(parent_call_id, text, meta) do
    %{
      type: :child_event,
      event_type: :child_event,
      source: :interview,
      transport: :streamable_http,
      parent_call_id: parent_call_id,
      runtime_source: "ouroboros",
      occurred_at_ms: System.system_time(:millisecond),
      payload: %{"token" => text, "meta" => meta}
    }
  end

  # `enqueue` already folds the synthetic event through `maybe_detect_
  # interview` (ambiguity-prefixed questions). This explicit merge guarantees
  # the left interview block also renders the bare question text and carries
  # the session id forward when the wire omits the `(ambiguity: …)` prefix.
  defp merge_interview(agent, parent_call_id, text, meta, session_id) do
    Agent.update(agent, fn state ->
      prev = state.interview || %{}

      iv =
        prev
        |> Map.merge(%{
          question: question_from(text),
          parent_call_id: parent_call_id || prev[:parent_call_id],
          waiting: false
        })
        |> maybe_put(:session_id, session_id)
        |> maybe_put(:milestone, meta_value(meta, "milestone"))
        |> maybe_put(:seed_ready, meta_value(meta, "seed_ready"))
        |> Map.delete(:answered)

      %{state | interview: iv, paused: false}
    end)
  end

  defp push_router_trace(agent, line) when is_binary(line) do
    Agent.update(agent, fn state ->
      prev = state.interview || %{}
      trace = [line | Map.get(prev, :router, [])] |> Enum.take(@router_trace_keep)
      %{state | interview: Map.put(prev, :router, trace)}
    end)
  end

  # The answerer model's streamed reasoning chunks (the main session's live
  # thinking while it decides PATH / reads code). Kept as a rolling buffer,
  # rendered in the LEFT transcript block — never the right MCP-internal pane.
  defp push_reasoning(agent, chunk) when is_binary(chunk) do
    Agent.update(agent, fn state ->
      prev = state.interview || %{}
      buf = [chunk | Map.get(prev, :reasoning, [])] |> Enum.take(@reasoning_keep)
      %{state | interview: Map.put(prev, :reasoning, buf)}
    end)
  end

  defp push_reasoning(_agent, _chunk), do: :ok

  # The shared three-party conversation timeline: MCP (question generator),
  # MAIN (the answerer/router — the main session's resolved turn), and YOU
  # (the operator's judgment). Newest-first, capped; the TUI renders it
  # color-coded by role so the dialectic reads as one conversation.
  defp push_dialogue(agent, role, text)
       when role in [:mcp, :main, :user] and is_binary(text) do
    trimmed = String.trim(text)

    if trimmed == "" or (role == :main and leaked_router_prompt?(trimmed)) do
      :ok
    else
      Agent.update(agent, fn state ->
        prev = state.interview || %{}

        log =
          [%{role: role, text: trimmed} | Map.get(prev, :dialogue, [])]
          |> Enum.take(@dialogue_keep)

        %{state | interview: Map.put(prev, :dialogue, log)}
      end)
    end
  end

  defp push_dialogue(_agent, _role, _text), do: :ok

  defp leaked_router_prompt?(text) when is_binary(text) do
    flat = String.replace(text, ~r/\s+/, " ")

    String.contains?(flat, [
      "You are the answerer/router half",
      "Routing rules (from the interview SKILL)",
      "Tool protocol",
      "Output exactly one directive as the first line",
      "ANSWER [from-code] <answer>",
      "ASK_USER <question for the human>"
    ]) or
      (String.length(flat) > 900 and
         String.contains?(flat, "ANSWER [from-code]") and
         String.contains?(flat, "ASK_USER"))
  end

  defp leaked_router_prompt?(_text), do: false

  # MCP wire-encodes the dialectic signal as `(ambiguity: 0.42) <question>`.
  # The operator asked to see that score immediately, so the MCP turn keeps
  # it inline instead of stripping it to the right-hand telemetry pane.
  defp mcp_turn_text(text) do
    case parse_ambiguity(text) do
      {:ok, score, question} when is_float(score) ->
        "(ambiguity #{:erlang.float_to_binary(score, decimals: 2)}) #{question}"

      _no_score ->
        String.trim(to_string(text))
    end
  end

  # The answerer commits `[from-code]` / `[from-research]` / `[from-user]`
  # answers; keep whatever prefix the model already produced, otherwise stamp
  # the routed source so the MAIN turn always declares where it came from.
  defp ensure_answer_prefix(payload, source) do
    trimmed = String.trim(payload)

    if Regex.match?(~r/^\[from-[a-z]+\]/, trimmed),
      do: trimmed,
      else: "[from-#{source}] " <> trimmed
  end

  defp enqueue_complete(agent, parent_call_id, reason) do
    enqueue(agent, %{
      type: :child_event,
      event_type: :child_event,
      source: :interview,
      transport: :streamable_http,
      parent_call_id: parent_call_id,
      runtime_source: "ouroboros",
      occurred_at_ms: System.system_time(:millisecond),
      payload: %{
        :kind => :interview_complete,
        :token => "interview complete (#{reason}) — 📍 Next: ooo seed",
        "meta" => %{"seed_ready" => true}
      }
    })

    Agent.update(agent, fn state ->
      iv =
        (state.interview || %{})
        |> Map.put(:seed_ready, true)
        |> Map.put(:complete, reason)
        |> Map.put(:waiting, false)

      %{state | interview: iv, interview_session: nil, interview_waiter: nil}
    end)

    push_dialogue(agent, :mcp, "interview complete (#{reason}) — next: ooo seed")
  end

  defp enqueue_failure(agent, parent_call_id, reason) do
    enqueue(agent, %{
      type: :parent_call_failed,
      event_type: :parent_call_failed,
      source: :terminal_runtime,
      transport: :streamable_http,
      parent_call_id: parent_call_id,
      runtime_source: "ouroboros",
      occurred_at_ms: System.system_time(:millisecond),
      payload: %{status: :failed, reason: inspect(reason)}
    })

    :ok
  end

  # --- runtime event poll: drain the ordered inbox -------------------------

  defp poll_runtime_event_fun(agent) do
    fn _state ->
      Agent.get_and_update(agent, fn state ->
        case :queue.out(state.inbox) do
          {{:value, event}, rest} -> {{:ok, event}, %{state | inbox: rest}}
          {:empty, _inbox} -> {:none, state}
        end
      end)
    end
  end

  # --- runtime event handling ----------------------------------------------

  # Pane/wonderTool folding happens at ingest time (see `enqueue/2`) so the
  # renderer reflects streaming on its own cadence. The loop still drains the
  # event for its bookkeeping/journaling path; nothing extra to do here.
  defp on_runtime_event_fun(_agent) do
    fn _runtime_event, _startup_result -> :ok end
  end

  defp fold_event(state, event) do
    state
    |> Map.update!(:parent, &safe_apply(ParentMcpPane, &1, event))
    |> Map.update!(:child, &safe_apply(ChildSessionPanes, &1, event))
    |> maybe_detect_wonder(event)
    |> maybe_detect_interview(event)
  end

  # The Ouroboros interview MCP wire-encodes its reasoning into the response:
  # the question text is prefixed `(ambiguity: 0.42) <question>` (a documented,
  # regex-parseable contract — authoring_handlers.py `_format_question_with_
  # ambiguity`) and structured `meta` carries milestone/seed-ready. We extract
  # only what is genuinely on the wire — never fabricate PATH routing.
  defp maybe_detect_interview(state, event) do
    text = interview_text(event)
    meta = interview_meta(event)

    case parse_ambiguity(text) do
      {:ok, score, question} ->
        prev = state.interview || %{}

        interview =
          prev
          |> Map.merge(%{
            question: clean_markdown(question),
            ambiguity: score,
            parent_call_id: Map.get(event, :parent_call_id) || prev[:parent_call_id],
            child_id: Map.get(event, :child_id) || prev[:child_id],
            waiting: false
          })
          |> merge_interview_meta(meta)
          |> Map.delete(:answered)

        %{state | interview: interview, paused: false}

      :none ->
        cond do
          state.interview && meta != %{} ->
            %{state | interview: merge_interview_meta(state.interview, meta)}

          meta != %{} && interview_meta?(meta) && String.trim(text) != "" ->
            prev = state.interview || %{}

            interview =
              prev
              |> Map.merge(%{
                question: clean_markdown(text),
                parent_call_id: Map.get(event, :parent_call_id) || prev[:parent_call_id],
                child_id: Map.get(event, :child_id) || prev[:child_id],
                waiting: false
              })
              |> merge_interview_meta(meta)
              |> Map.delete(:answered)

            %{state | interview: interview, paused: false}

          true ->
            state
        end
    end
  rescue
    _exception -> state
  end

  defp merge_interview_meta(interview, meta) when is_map(interview) do
    interview
    |> maybe_put(:ambiguity, numeric_meta_value(meta, "ambiguity_score"))
    |> maybe_put(:milestone, meta_value(meta, "milestone"))
    |> maybe_put(:seed_ready, meta_value(meta, "seed_ready"))
    |> maybe_put(:breakdown, meta_value(meta, "ambiguity_breakdown"))
    |> maybe_put(:session_id, meta_value(meta, "session_id"))
    |> maybe_put(:mcp_reasoning, reasoning_lines(meta))
    |> maybe_put(:mcp_reasoning_state, meta_value(meta, "interview_reasoning"))
  end

  defp interview_meta?(meta) when is_map(meta) do
    Enum.any?(
      ["internal_reasoning", "interview_reasoning", "ambiguity_score", "milestone", "seed_ready"],
      &(not is_nil(meta_value(meta, &1)))
    )
  end

  defp interview_meta?(_meta), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp numeric_meta_value(meta, key) do
    case meta_value(meta, key) do
      value when is_float(value) -> value
      value when is_integer(value) -> value / 1
      value when is_binary(value) -> parse_float(value)
      _other -> nil
    end
  end

  defp reasoning_lines(meta) when is_map(meta) do
    meta
    |> meta_value("internal_reasoning")
    |> normalize_reasoning_lines()
  end

  defp reasoning_lines(_meta), do: []

  defp normalize_reasoning_lines(lines) when is_list(lines) do
    lines
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(12)
  end

  defp normalize_reasoning_lines(line) when is_binary(line) do
    line
    |> String.split(~r/\r?\n/)
    |> normalize_reasoning_lines()
  end

  defp normalize_reasoning_lines(_value), do: []

  defp decode_text_meta(text) when is_binary(text) do
    trimmed = String.trim(text)

    if String.starts_with?(trimmed, "{") do
      case Ourocode.Json.decode(trimmed) do
        {:ok, %{} = body} -> body
        _error -> %{}
      end
    else
      %{}
    end
  end

  defp decode_text_meta(_text), do: %{}

  defp meta_value(meta, key) when is_map(meta) do
    case Map.fetch(meta, key) do
      {:ok, value} -> value
      :error -> Map.get(meta, safe_atom(key))
    end
  end

  defp meta_value(_meta, _key), do: nil

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  @ambiguity_re ~r/\(ambiguity:\s*([0-9]*\.?[0-9]+)\)\s*(.*)/s

  defp parse_ambiguity(text) when is_binary(text) do
    case Regex.run(@ambiguity_re, text) do
      [_, score, question] ->
        {:ok, parse_float(score), String.trim(question)}

      _no_match ->
        :none
    end
  end

  defp parse_ambiguity(_text), do: :none

  defp parse_float(value) do
    case Float.parse(value) do
      {f, _rest} -> f
      :error -> nil
    end
  end

  defp clean_markdown(text) when is_binary(text) do
    text
    |> String.replace(~r/(\*\*|__)(.*?)\1/s, "\\2")
    |> String.replace(~r/`([^`]+)`/, "\\1")
    |> String.replace(~r/^\s{0,3}\#{1,6}\s+/m, "")
    |> String.trim()
  end

  defp clean_markdown(text), do: to_string(text)

  defp interview_text(event) when is_map(event) do
    payload = if is_map(event[:payload]), do: event[:payload], else: %{}

    [
      event[:token],
      event[:content],
      event[:text],
      event[:question],
      payload[:token],
      payload["token"],
      payload[:content],
      payload["content"],
      payload[:text],
      payload["text"],
      payload[:question],
      payload["question"]
    ]
    |> Enum.find("", &(is_binary(&1) and &1 != ""))
  end

  defp interview_text(_event), do: ""

  defp interview_meta(event) when is_map(event) do
    payload = if is_map(event[:payload]), do: event[:payload], else: %{}

    [event[:meta], event["meta"], payload[:meta], payload["meta"]]
    |> Enum.find(%{}, &is_map/1)
  end

  defp interview_meta(_event), do: %{}

  defp safe_apply(module, pane_state, event) do
    module.apply_event(pane_state, event)
  rescue
    _exception -> pane_state
  end

  defp maybe_detect_wonder(state, runtime_event) do
    case InteractionDetector.detect(detector_payload(runtime_event)) do
      {:ok, detection} -> Map.put(state, :wonder, detection)
      :ignore -> state
    end
  rescue
    _exception -> state
  end

  defp detector_payload(event) when is_map(event) do
    case Map.get(event, :payload, event) do
      payload when is_map(payload) -> payload
      _other -> event
    end
  end

  # --- helpers -------------------------------------------------------------

  defp mcp_url do
    System.get_env("OUROCODE_MCP_URL") || "http://127.0.0.1:4000/mcp"
  end
end
