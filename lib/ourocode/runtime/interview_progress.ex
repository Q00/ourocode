defmodule Ourocode.Runtime.InterviewProgress do
  @moduledoc """
  Updates live interview progress state for the terminal renderer.
  """

  alias Ourocode.Runtime.InterviewState

  @spec mark_dispatching(pid(), map(), String.t()) :: :ok
  def mark_dispatching(agent, task_request, parent_call_id) when is_pid(agent) do
    prompt = Map.get(task_request, :task_input, "")

    Agent.update(agent, fn state ->
      prev = state.interview || %{}

      dialogue =
        case String.trim(prompt) do
          "" -> Map.get(prev, :dialogue, [])
          text -> InterviewState.prepend_dialogue_turn(Map.get(prev, :dialogue, []), :user, text)
        end

      iv =
        prev
        |> Map.merge(%{
          parent_call_id: parent_call_id,
          question: "",
          waiting_started_monotonic_ms: monotonic_ms(),
          waiting: true,
          status: "starting interview session",
          dialogue: dialogue
        })
        |> Map.delete(:answered)
        |> Map.delete(:question_options)

      session = %{
        parent_call_id: parent_call_id,
        label: "ooo interview",
        status: "starting interview session",
        round: 0
      }

      state
      |> Map.merge(%{interview: iv, interview_session: session, paused: false, wonder: nil})
    end)
  end

  @spec mark_waiting(pid(), map()) :: :ok
  def mark_waiting(agent, st) when is_pid(agent) do
    Agent.update(agent, fn state ->
      prev = state.interview || %{}
      answered? = answered?(prev)

      iv =
        prev
        |> Map.merge(%{
          parent_call_id: st.parent_call_id || prev[:parent_call_id],
          question: waiting_question(prev, answered?),
          waiting_started_monotonic_ms: waiting_started_ms(prev, st.parent_call_id),
          waiting: true,
          status: waiting_status(st.round, answered?)
        })
        |> maybe_clear_question_options(answered?)
        |> Map.delete(:answered)

      session = %{
        parent_call_id: st.parent_call_id,
        label: "ooo interview",
        status: waiting_status(st.round, answered?),
        round: st.round
      }

      %{state | interview: iv, interview_session: session, paused: false}
    end)
  end

  @spec mark_answer_sync(pid(), String.t()) :: :ok
  def mark_answer_sync(agent, status) when is_pid(agent) and is_binary(status) do
    Agent.update(agent, fn state ->
      prev = state.interview || %{}

      iv =
        prev
        |> Map.merge(%{
          waiting: true,
          status: status,
          waiting_started_monotonic_ms: waiting_started_ms(prev, Map.get(prev, :parent_call_id))
        })
        |> Map.put(:question, "")
        |> Map.delete(:question_options)

      %{state | interview: iv, paused: false}
    end)
  end

  @spec waiting_status(pos_integer()) :: String.t()
  def waiting_status(1), do: "waiting for MCP interview question"
  def waiting_status(_round), do: "waiting for MCP follow-up question"

  defp waiting_status(1, _answered?), do: waiting_status(1)
  defp waiting_status(_round, true), do: "preparing next interview question"
  defp waiting_status(round, _answered?), do: waiting_status(round)

  defp answered?(%{answered: text}) when is_binary(text), do: String.trim(text) != ""
  defp answered?(_prev), do: false

  defp waiting_question(_prev, true), do: ""
  defp waiting_question(prev, _answered?), do: Map.get(prev, :question, "")

  defp maybe_clear_question_options(interview, true), do: Map.delete(interview, :question_options)
  defp maybe_clear_question_options(interview, _answered?), do: interview

  defp waiting_started_ms(prev, parent_call_id) do
    same_parent? = Map.get(prev, :parent_call_id) == parent_call_id

    if same_parent? and is_integer(Map.get(prev, :waiting_started_monotonic_ms)),
      do: Map.get(prev, :waiting_started_monotonic_ms),
      else: monotonic_ms()
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
