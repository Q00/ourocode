defmodule Ourocode.Runtime.InterviewProgressTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.InterviewProgress

  test "marks interview dispatching with user prompt dialogue" do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{interview: nil, interview_session: nil, paused: true}
      end)

    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    InterviewProgress.mark_dispatching(
      agent,
      %{task_input: "ooo interview improve docs"},
      "parent-1"
    )

    state = Agent.get(agent, & &1)
    assert state.paused == false
    assert state.interview.waiting == true
    assert state.interview.status == "starting interview session"
    assert state.interview.parent_call_id == "parent-1"
    assert is_integer(state.interview.waiting_started_monotonic_ms)
    assert [%{role: :user, text: "ooo interview improve docs"}] = state.interview.dialogue
    assert state.interview_session.round == 0
  end

  test "does not open an optimistic PM picker before the transport is ready" do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          interview: %{
            question: "Which package manager?",
            question_options: [%{label: "npm", description: "Node default"}]
          },
          interview_session: nil,
          wonder: %{request_id: "stale-picker"},
          paused: true
        }
      end)

    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    InterviewProgress.mark_dispatching(
      agent,
      %{task_input: "ooo pm build onboarding"},
      "parent-fast"
    )

    state = Agent.get(agent, & &1)
    assert state.wonder == nil
    assert state.interview.waiting == true
    assert state.interview.status == "starting interview session"
    assert state.interview.question == ""
    refute Map.has_key?(state.interview, :question_options)
  end

  test "marks interview waiting rounds with stable status text" do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          interview: %{
            parent_call_id: "parent-2",
            answered: "old",
            last_answer: "old",
            question: "Which proof matters most?",
            question_options: [%{label: "Tests", description: "Run checks"}],
            waiting_started_monotonic_ms: 123
          },
          interview_session: nil,
          paused: true
        }
      end)

    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    InterviewProgress.mark_waiting(agent, %{parent_call_id: "parent-2", round: 2})

    state = Agent.get(agent, & &1)
    assert state.interview.parent_call_id == "parent-2"
    assert state.interview.status == "preparing next interview question"
    assert state.interview.question == ""
    assert state.interview.waiting_started_monotonic_ms == 123
    refute Map.has_key?(state.interview, :answered)
    refute Map.has_key?(state.interview, :question_options)
    assert state.interview_session.round == 2
    assert state.interview_session.status == "preparing next interview question"
    assert InterviewProgress.waiting_status(1) == "waiting for MCP interview question"
  end

  test "marks accepted answer sync without reviving stale choices" do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          interview: %{
            parent_call_id: "parent-3",
            last_answer: "Plugin is loaded",
            question: "Which proof matters most?",
            question_options: [%{label: "Verifier", description: "Run checks"}]
          },
          paused: true
        }
      end)

    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    InterviewProgress.mark_answer_sync(agent, "opening interview session to send answer")

    state = Agent.get(agent, & &1)
    assert state.paused == false
    assert state.interview.waiting == true
    assert state.interview.status == "opening interview session to send answer"
    assert state.interview.question == ""
    assert is_integer(state.interview.waiting_started_monotonic_ms)
    refute Map.has_key?(state.interview, :question_options)
  end
end
