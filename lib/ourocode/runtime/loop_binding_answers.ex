defmodule Ourocode.Runtime.LoopBindingAnswers do
  @moduledoc """
  Applies user answers and cancellation actions to loop binding state.
  """

  alias Ourocode.Runtime.{InterviewEvents, WonderAnswer}

  @type enqueue_fun :: (pid(), map() -> :ok)

  @spec clear_wonder(pid()) :: :ok
  def clear_wonder(agent) when is_pid(agent) do
    Agent.update(agent, &Map.put(&1, :wonder, nil))
  end

  @spec pause_wonder(pid()) :: :ok
  def pause_wonder(agent) when is_pid(agent) do
    Agent.update(agent, &Map.put(&1, :paused, true))
  end

  @spec resume_wonder(pid()) :: :ok
  def resume_wonder(agent) when is_pid(agent) do
    Agent.update(agent, &Map.put(&1, :paused, false))
  end

  @spec answer_interview(pid(), String.t(), enqueue_fun()) ::
          {:ok, String.t()} | {:error, :no_active_interview}
  def answer_interview(agent, text, enqueue) when is_pid(agent) and is_binary(text) do
    text = clean_text(text)

    case Agent.get(agent, &{&1.interview, Map.get(&1, :interview_waiter)}) do
      {%{} = interview, waiter} ->
        enqueue.(agent, InterviewEvents.answer_ack(interview, text))

        Agent.update(agent, fn state ->
          state
          |> InterviewEvents.answer_state(interview, text)
          |> maybe_buffer_answer(waiter, text)
        end)

        if is_pid(waiter), do: send(waiter, {:interview_answer, text})

        {:ok, text}

      {_none, _waiter} ->
        {:error, :no_active_interview}
    end
  end

  defp clean_text(text) when is_binary(text) do
    text
    |> String.replace_invalid("")
    |> String.replace(<<0xFFFD::utf8>>, "")
    |> String.trim()
  end

  @spec cancel_interview(pid(), enqueue_fun()) ::
          {:ok, String.t()} | {:error, :no_active_interview}
  def cancel_interview(agent, enqueue) when is_pid(agent) do
    case Agent.get(agent, &{&1.interview, Map.get(&1, :interview_waiter)}) do
      {%{} = interview, waiter} ->
        parent_call_id = Map.get(interview, :parent_call_id) || "parent-interview"

        enqueue.(agent, InterviewEvents.answer_ack(interview, "cancel"))
        enqueue.(agent, InterviewEvents.complete(parent_call_id, :user_done))

        Agent.update(agent, fn state ->
          state
          |> InterviewEvents.complete_state(:user_done)
          |> mark_cancelled_interview(parent_call_id)
          |> Map.merge(%{
            wonder: nil,
            interview_waiter: nil,
            pending_interview_answer: nil,
            paused: false
          })
        end)

        if is_pid(waiter), do: send(waiter, {:interview_answer, "cancel"})

        {:ok, "cancel"}

      {_none, _waiter} ->
        {:error, :no_active_interview}
    end
  end

  @spec answer_wonder(pid(), term(), enqueue_fun()) ::
          {:ok, map()} | {:error, :no_active_wonder | term()}
  def answer_wonder(agent, selection, enqueue) when is_pid(agent) do
    case Agent.get(agent, &{&1.wonder, Map.get(&1, :interview_waiter)}) do
      {%{request: request} = detection, waiter} ->
        case WonderAnswer.capture(request, selection) do
          {:ok, combined} ->
            enqueue.(agent, WonderAnswer.ack_event(detection, combined))
            enqueue.(agent, decision_answered_event(detection, combined))
            Agent.update(agent, &accept_wonder_answer(&1, detection, combined.handback))

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

  @spec cancel_wonder(pid(), String.t(), enqueue_fun()) ::
          {:ok, map()} | {:error, :no_active_wonder}
  def cancel_wonder(agent, reason, enqueue) when is_pid(agent) and is_binary(reason) do
    case Agent.get(agent, &{&1.wonder, Map.get(&1, :interview_waiter)}) do
      {%{} = detection, waiter} ->
        cancelled = WonderAnswer.cancelled(detection, reason)

        enqueue.(agent, WonderAnswer.cancel_event(detection, cancelled))
        enqueue.(agent, decision_cancelled_event(detection, cancelled))

        Agent.update(agent, fn state ->
          state
          |> maybe_complete_cancelled_interview()
          |> maybe_mark_cancelled_detection(detection)
          |> Map.merge(%{
            wonder: nil,
            interview_waiter: nil,
            paused: false
          })
        end)

        if is_pid(waiter) do
          send(waiter, {:interview_answer, "cancel"})
        else
          Agent.update(agent, &Map.put(&1, :pending_interview_answer, "cancel"))
        end

        {:ok, cancelled}

      {_no_active, _waiter} ->
        {:error, :no_active_wonder}
    end
  end

  defp maybe_complete_cancelled_interview(%{interview: %{} = _interview} = state) do
    InterviewEvents.complete_state(state, :user_done)
  end

  defp maybe_complete_cancelled_interview(state), do: state

  defp maybe_buffer_answer(state, waiter, _text) when is_pid(waiter), do: state

  defp maybe_buffer_answer(state, _waiter, text),
    do: Map.put(state, :pending_interview_answer, text)

  defp maybe_mark_cancelled_detection(state, detection) do
    case parent_call_id(detection) || get_in(state, [:interview, :parent_call_id]) do
      parent_call_id when is_binary(parent_call_id) ->
        mark_cancelled_interview(state, parent_call_id)

      _none ->
        state
    end
  end

  defp mark_cancelled_interview(state, parent_call_id) when is_binary(parent_call_id) do
    cancelled =
      state
      |> Map.get(:cancelled_interviews, MapSet.new())
      |> MapSet.put(parent_call_id)

    Map.put(state, :cancelled_interviews, cancelled)
  end

  defp parent_call_id(%{parent_call_id: parent_call_id}), do: parent_call_id
  defp parent_call_id(%{request: %{parent_call_id: parent_call_id}}), do: parent_call_id
  defp parent_call_id(%{request: %{"parent_call_id" => parent_call_id}}), do: parent_call_id
  defp parent_call_id(%{request: %{"parentCallId" => parent_call_id}}), do: parent_call_id
  defp parent_call_id(_detection), do: nil

  defp decision_answered_event(detection, combined) do
    %{
      type: :decision_answered,
      event_type: :decision_answered,
      source: :wonder_tool,
      runtime_source: "ourocode",
      transport: :local,
      decision_id: decision_id(detection),
      parent_call_id: parent_call_id(detection),
      child_id: child_id(detection),
      selected_label: get_in(combined, [:result, :selected_label]),
      occurred_at_ms: System.system_time(:millisecond)
    }
    |> drop_nil_values()
  end

  defp decision_cancelled_event(detection, cancelled) do
    %{
      type: :decision_cancelled,
      event_type: :decision_cancelled,
      source: :wonder_tool,
      runtime_source: "ourocode",
      transport: :local,
      decision_id: decision_id(detection),
      parent_call_id: parent_call_id(detection),
      child_id: child_id(detection),
      reason: Map.get(cancelled, :reason),
      occurred_at_ms: System.system_time(:millisecond)
    }
    |> drop_nil_values()
  end

  defp decision_id(%{request_id: request_id}), do: request_id
  defp decision_id(%{request: %{request_id: request_id}}), do: request_id
  defp decision_id(%{request: %{"request_id" => request_id}}), do: request_id
  defp decision_id(%{request: %{"requestId" => request_id}}), do: request_id

  defp decision_id(detection),
    do: parent_call_id(detection) && parent_call_id(detection) <> ":decision"

  defp child_id(%{child_id: child_id}), do: child_id
  defp child_id(%{request: %{child_id: child_id}}), do: child_id
  defp child_id(%{request: %{"child_id" => child_id}}), do: child_id
  defp child_id(%{request: %{"childID" => child_id}}), do: child_id
  defp child_id(_detection), do: nil

  defp accept_wonder_answer(state, detection, text) do
    state =
      case Map.get(state, :interview) do
        %{} = interview ->
          interview =
            detection
            |> wonder_question_state()
            |> Map.merge(interview, fn _key, detected, current ->
              if blank?(current), do: detected, else: current
            end)

          InterviewEvents.answer_state(state, interview, text)

        _none ->
          state
      end

    state
    |> Map.put(:wonder, nil)
    |> Map.put(:pending_interview_answer, text)
  end

  defp wonder_question_state(%{request: %{questions: [question | _rest]}})
       when is_map(question) do
    %{
      question: value(question, :question, ""),
      question_options: value(question, :options, [])
    }
  end

  defp wonder_question_state(_detection), do: %{}

  defp blank?(value), do: value in [nil, "", []]

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp value(_map, _key, default), do: default

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
