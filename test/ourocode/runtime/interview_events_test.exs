defmodule Ourocode.Runtime.InterviewEventsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.InterviewEvents

  test "answer_ack records the user answer against the active interview child" do
    assert %{
             type: :child_event,
             event_type: :child_event,
             source: :interview,
             transport: :streamable_http,
             parent_call_id: "parent-1",
             child_id: "child-1",
             runtime_source: "ouroboros",
             occurred_at_ms: 100,
             payload: %{kind: :interview_answer, token: "you: PostgreSQL"}
           } =
             InterviewEvents.answer_ack(
               %{parent_call_id: "parent-1", child_id: "child-1"},
               "PostgreSQL",
               100
             )
  end

  test "answer state preserves the accepted turn for transition rendering" do
    state =
      %{
        interview: %{
          question: "Which proof matters most?",
          question_options: [%{label: "Tests", description: "Run checks"}],
          parent_call_id: "parent-1"
        },
        interview_waiter: self(),
        paused: true
      }
      |> InterviewEvents.answer_state(
        %{
          question: "Which proof matters most?",
          question_options: [%{label: "Tests", description: "Run checks"}],
          parent_call_id: "parent-1"
        },
        "Run the verifier"
      )

    assert state.paused == false
    assert state.interview_waiter == nil
    assert state.interview.answered == "Run the verifier"
    assert state.interview.last_answer == "Run the verifier"
    assert state.interview.last_answered_question == "Which proof matters most?"
    assert state.interview.last_question_options == [%{label: "Tests", description: "Run checks"}]
    assert state.interview.status == "answer accepted - preparing next question"
    assert state.interview.waiting == true
    assert state.interview.question == ""
    assert is_integer(state.interview.waiting_started_monotonic_ms)
    refute Map.has_key?(state.interview, :question_options)
  end

  test "server_error builds resumable status event and state projection" do
    event = InterviewEvents.server_error("parent-1", "model unavailable", "session-1", 200)

    assert event.payload.token ==
             "MCP question generator unavailable: model unavailable  (session=session-1, resume available)"

    state =
      %{
        interview: %{answered: "old", waiting: true, question_options: [%{label: "A"}]},
        interview_waiter: self(),
        pending_interview_answer: "old",
        paused: true,
        wonder: %{active: true}
      }
      |> InterviewEvents.server_error_state("model unavailable", "session-1")

    assert state.interview.status == "MCP question generator unavailable: model unavailable"
    assert state.interview.waiting == false
    assert state.interview.resumable == true
    assert state.interview.session_id == "session-1"
    refute Map.has_key?(state.interview, :answered)
    refute Map.has_key?(state.interview, :question_options)
    assert state.interview_waiter == nil
    assert state.pending_interview_answer == nil
    assert state.paused == false
    assert state.wonder == nil
  end

  test "complete event and state mark the interview seed-ready" do
    event = InterviewEvents.complete("parent-1", :seed_ready, 300)

    assert event.payload.kind == :interview_complete
    assert event.payload["meta"] == %{"seed_ready" => true}
    assert event.payload.token =~ "ooo seed"

    state =
      %{
        interview: %{waiting: true, question: "Pending?", question_options: [%{label: "A"}]},
        interview_session: %{id: "session-1"},
        interview_waiter: self()
      }
      |> InterviewEvents.complete_state(:seed_ready)

    assert state.interview.seed_ready == true
    assert state.interview.complete == :seed_ready
    assert state.interview.waiting == false
    assert state.interview.status == "interview complete: seed_ready"
    assert state.interview.question == ""
    refute Map.has_key?(state.interview, :question_options)
    assert state.interview_session == nil
    assert state.interview_waiter == nil
  end

  test "failure event keeps inspected reason in parent failure payload" do
    assert %{
             type: :parent_call_failed,
             event_type: :parent_call_failed,
             parent_call_id: "parent-1",
             payload: %{status: :failed, reason: "{:transport_failed, :timeout}"}
           } = InterviewEvents.failure("parent-1", {:transport_failed, :timeout}, 400)
  end

  test "failure state clears waiting interview controls" do
    state =
      %{
        interview: %{
          waiting: true,
          answered: "old",
          question_options: [%{label: "A"}]
        },
        interview_session: %{id: "session-1"},
        interview_waiter: self(),
        pending_interview_answer: "old",
        paused: true,
        wonder: %{active: true}
      }
      |> InterviewEvents.failure_state({:transport_failed, :interview_initial_question_timeout})

    assert state.interview.status ==
             "interview session did not open; submit the same command to retry"

    assert state.interview.waiting == false
    assert state.interview_session == nil
    assert state.interview_waiter == nil
    assert state.pending_interview_answer == nil
    assert state.paused == false
    assert state.wonder == nil
    refute Map.has_key?(state.interview, :answered)
    refute Map.has_key?(state.interview, :question_options)
  end
end
