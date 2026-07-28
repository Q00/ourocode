defmodule Ourocode.Runtime.LocalInterviewFallback do
  alias Ourocode.Model

  alias Ourocode.Runtime.{
    InterviewEvents,
    InterviewRouter,
    InterviewState,
    InterviewWonderPrompt,
    LoopBindingEventFlow,
    LoopBindingInterviewAwaiter,
    WorkflowHarness
  }

  import Ourocode.Runtime.LocalInterviewFallback.Support,
    only: [
      clean_text: 1,
      continue_interview?: 1,
      local_error_message: 1,
      normalize_options: 1,
      preview_profile: 1,
      router_question: 3,
      seed_ready_summary: 1,
      usable?: 1
    ]

  @spec start(pid(), map(), String.t(), String.t(), Model.t(), String.t()) :: :ok
  def start(agent, task_request, parent_call_id, workflow_run_id, %Model{} = model, project_dir)
      when is_pid(agent) and is_map(task_request) do
    spawn(fn -> run(agent, task_request, parent_call_id, workflow_run_id, model, project_dir) end)
    :ok
  end

  @spec unavailable?(map() | nil) :: boolean()
  def unavailable?(%{mode: mode}) when mode in [:disabled, :unavailable], do: true
  def unavailable?(_handle), do: false

  defp run(agent, task_request, parent_call_id, workflow_run_id, model, project_dir) do
    profile = preview_profile(task_request)

    if Model.ready?(model) do
      push_trace(
        agent,
        "MCP daemon unavailable; asking #{model.label} to run the #{profile.workflow} interview"
      )

      local_round(agent, profile, parent_call_id, workflow_run_id, model, project_dir, [], 1)
    else
      fail(agent, parent_call_id, workflow_run_id, {:model_not_ready, model.status})
    end
  end

  defp local_round(
         agent,
         profile,
         parent_call_id,
         workflow_run_id,
         model,
         project_dir,
         turns,
         round
       ) do
    if round > profile.max_rounds do
      continuation_gate(
        agent,
        profile,
        parent_call_id,
        workflow_run_id,
        model,
        project_dir,
        turns
      )
    else
      case generate_turn(agent, model, profile, project_dir, turns, round) do
        {:ok, {:question, question, options}} ->
          ask_round(agent, parent_call_id, round, question, options)

          case LoopBindingInterviewAwaiter.await(agent, parent_call_id, question, options) do
            {:done, text} ->
              complete(agent, parent_call_id, workflow_run_id, text)

            {:answer, answer} ->
              answer = clean_text(answer)
              push_dialogue(agent, :user, answer)

              local_round(
                agent,
                profile,
                parent_call_id,
                workflow_run_id,
                model,
                project_dir,
                turns ++ [%{question: question, answer: answer}],
                round + 1
              )
          end

        {:error, reason} ->
          fail(agent, parent_call_id, workflow_run_id, reason)
      end
    end
  end

  defp continuation_gate(
         agent,
         profile,
         parent_call_id,
         workflow_run_id,
         model,
         project_dir,
         turns
       ) do
    question = "Do you want to keep interviewing or generate the seed now?"

    options = [
      %{label: "Continue interview", description: "ask more Codex-generated PM questions"},
      %{label: "Generate seed now", description: "finish the interview and move to ooo seed"},
      %{label: "Stop for now", description: "close the interview without adding more answers"}
    ]

    ask_round(agent, parent_call_id, profile.max_rounds + 1, question, options)

    case LoopBindingInterviewAwaiter.await(agent, parent_call_id, question, options) do
      {:done, text} ->
        complete(agent, parent_call_id, workflow_run_id, text)

      {:answer, answer} ->
        push_dialogue(agent, :user, answer)

        if continue_interview?(answer) do
          local_round(
            agent,
            profile,
            parent_call_id,
            workflow_run_id,
            model,
            project_dir,
            turns,
            1
          )
        else
          complete(agent, parent_call_id, workflow_run_id, seed_ready_summary(answer))
        end
    end
  end

  defp generate_turn(agent, model, profile, project_dir, turns, round) do
    question = router_question(profile, turns, round)
    push_trace(agent, "Codex router generating local #{profile.workflow} question #{round}")

    case InterviewRouter.decide(question, %{project_dir: project_dir, streak: 0}, model,
           on_trace: fn line -> push_trace(agent, line) end,
           on_reason: fn chunk -> push_reasoning(agent, chunk) end
         ) do
      {:ask_user, question, options} ->
        question = clean_text(question)
        options = normalize_options(options)

        if usable?(question) and length(options) >= 2 do
          {:ok, {:question, question, options}}
        else
          {:error, :router_question_or_options_missing}
        end

      {:answer, payload, source} ->
        {:error, {:unexpected_router_answer, source, payload}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ask_round(agent, parent_call_id, round, question, options) do
    push_dialogue(agent, :main, "-> asking you: " <> question)

    LoopBindingEventFlow.enqueue(
      agent,
      InterviewWonderPrompt.event(parent_call_id, round, question, options)
    )
  end

  defp complete(agent, parent_call_id, workflow_run_id, summary) do
    if usable?(summary) do
      push_dialogue(agent, :main, summary)
    end

    LoopBindingEventFlow.enqueue(
      agent,
      WorkflowHarness.completed_event(parent_call_id, :local_preview, run_id: workflow_run_id)
    )

    LoopBindingEventFlow.enqueue(agent, InterviewEvents.complete(parent_call_id, :local_preview))
    Agent.update(agent, &InterviewEvents.complete_state(&1, :local_preview))
    push_dialogue(agent, :main, "AI interview fallback complete - run ooo seed when ready")
  end

  defp fail(agent, parent_call_id, workflow_run_id, reason) do
    message = local_error_message(reason)

    LoopBindingEventFlow.enqueue(
      agent,
      WorkflowHarness.failure_event(parent_call_id, {:local_ai_question_failed, reason},
        run_id: workflow_run_id
      )
    )

    LoopBindingEventFlow.enqueue(
      agent,
      InterviewEvents.server_error(parent_call_id, message, nil)
    )

    Agent.update(agent, &InterviewEvents.server_error_state(&1, message, nil))
    push_dialogue(agent, :main, "AI question generation failed: " <> message)
  end

  defp push_trace(agent, line) do
    Agent.update(agent, fn state -> InterviewState.add_router_trace(state, line) end)
  end

  defp push_reasoning(agent, chunk) do
    Agent.update(agent, fn state -> InterviewState.add_reasoning(state, chunk) end)
  end

  defp push_dialogue(agent, role, text) do
    Agent.update(agent, fn state -> InterviewState.add_dialogue(state, role, text) end)
  end
end
