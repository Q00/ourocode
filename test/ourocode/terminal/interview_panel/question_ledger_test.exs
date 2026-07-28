defmodule Ourocode.Terminal.InterviewPanel.QuestionLedgerTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.InterviewPanel.QuestionLedger

  test "groups interview dialogue into selectable question blocks" do
    interview = %{
      dialogue: [
        %{role: :user, text: "Run the verifier"},
        %{role: :main, text: "checked the local test surface"},
        %{role: :mcp, text: "Which proof matters most?"},
        %{role: :user, text: "Keep the ledger compact"},
        %{role: :mcp, text: "How should questions render?"}
      ]
    }

    ledger = QuestionLedger.from_interview(interview)

    assert ledger.kind == :interview_question_ledger
    assert ledger.block_count == 2

    assert [
             %{
               index: 1,
               kind: :interview_question,
               question: "How should questions render?",
               answer: "Keep the ledger compact",
               status: :answered,
               selectable?: true
             },
             %{
               index: 2,
               question: "Which proof matters most?",
               answer: "Run the verifier",
               reasoning: ["checked the local test surface"],
               status: :answered,
               selected?: true
             }
           ] = ledger.blocks
  end

  test "transition state becomes a generating block with reasoning and activity detail" do
    interview = %{
      waiting: true,
      last_answered_question: "Which proof matters most?",
      last_answer: "Run the verifier",
      mcp_reasoning: ["answer received", "building follow-up"],
      mcp_activity: ["session interview-1 streamed an update"],
      last_question_options: [
        %{label: "Health checks", description: "Run local checks"}
      ]
    }

    assert %{
             blocks: [
               %{
                 status: :generating,
                 question: "Which proof matters most?",
                 answer: "Run the verifier",
                 detail_lines: detail_lines,
                 selected?: true
               }
             ]
           } = QuestionLedger.from_interview(interview)

    assert {"Answer", "Run the verifier"} in detail_lines
    assert {"Reason", "answer received"} in detail_lines
    assert {"MCP", "session interview-1 streamed an update"} in detail_lines
    assert {"Choice", "Health checks - Run local checks"} in detail_lines
  end

  test "rows hide the active unanswered block when requested" do
    interview = %{
      dialogue: [
        %{role: :mcp, text: "Current question"},
        %{role: :user, text: "Initial goal"}
      ],
      question: "Current question"
    }

    assert QuestionLedger.rows(interview, include_current?: false) == []
    assert [{"Questions", :dim} | rows] = QuestionLedger.rows(interview)
    assert {"- [pending] Q1 Current question", :strong} in rows
  end

  test "does not render completion notices as pending questions" do
    interview = %{
      complete: :local_preview,
      dialogue: [
        %{role: :mcp, text: "AI interview fallback complete - run ooo seed when ready"},
        %{role: :user, text: "Accounts and sharing"},
        %{role: :mcp, text: "What should stay out of scope?"}
      ]
    }

    assert %{blocks: [%{question: "What should stay out of scope?", status: :answered}]} =
             QuestionLedger.from_interview(interview)

    rows = QuestionLedger.rows(interview)

    refute Enum.any?(
             rows,
             &match?({"- [pending] Q1 AI interview fallback complete" <> _, _}, &1)
           )
  end

  test "rows keep previous answers above an active picker without duplicating current question" do
    interview = %{
      dialogue: [
        %{role: :mcp, text: "Current question"},
        %{role: :user, text: "First answer"},
        %{role: :mcp, text: "First question"}
      ],
      question: "Current question"
    }

    text =
      interview
      |> QuestionLedger.rows(include_current?: false)
      |> Enum.map_join("\n", fn
        {line, _style} -> line
        :rule -> "----"
      end)

    assert text =~ "- [answered] Q1 First question"
    assert text =~ "Answer  First answer"
    refute text =~ "Current question"
  end

  test "explicit selection opens an older question while other blocks stay collapsed" do
    interview = %{
      dialogue: [
        %{role: :user, text: "Second answer"},
        %{role: :main, text: "second reasoning"},
        %{role: :mcp, text: "Second question"},
        %{role: :user, text: "First answer"},
        %{role: :main, text: "first reasoning"},
        %{role: :mcp, text: "First question"}
      ]
    }

    first_id =
      interview
      |> QuestionLedger.from_interview()
      |> Map.fetch!(:blocks)
      |> List.first()
      |> Map.fetch!(:id)

    selected_interview = Map.put(interview, :selected_question_block_id, first_id)

    assert [
             %{question: "First question", selected?: true},
             %{question: "Second question", selected?: false}
           ] = QuestionLedger.from_interview(selected_interview).blocks

    text =
      selected_interview
      |> QuestionLedger.rows()
      |> Enum.map_join("\n", fn
        {line, _style} -> line
        :rule -> "----"
      end)

    assert text =~ "- [answered] Q1 First question"
    assert text =~ "Answer  First answer"
    assert text =~ "Reason   first reasoning"
    assert text =~ "+ [answered] Q2 Second question"
    refute text =~ "Answer  Second answer"
    refute text =~ "Reason   second reasoning"
  end

  test "hovered unselected rows use hover styling" do
    interview = %{
      dialogue: [
        %{role: :user, text: "Second answer"},
        %{role: :mcp, text: "Second question"},
        %{role: :user, text: "First answer"},
        %{role: :mcp, text: "First question"}
      ]
    }

    first_id =
      interview
      |> QuestionLedger.from_interview()
      |> Map.fetch!(:blocks)
      |> List.first()
      |> Map.fetch!(:id)

    rows =
      interview
      |> Map.put(:hovered_question_block_id, first_id)
      |> QuestionLedger.rows()

    assert {"+ [answered] Q1 First question", :warn} in rows
    assert {"- [answered] Q2 Second question", :strong} in rows
  end

  test "block ids stay stable when a question receives an answer" do
    pending = %{dialogue: [%{role: :mcp, text: "Stable question"}]}

    answered = %{
      dialogue: [%{role: :user, text: "Answer"}, %{role: :mcp, text: "Stable question"}]
    }

    assert pending_id =
             pending
             |> QuestionLedger.from_interview()
             |> Map.fetch!(:blocks)
             |> List.first()
             |> Map.fetch!(:id)

    assert answered_id =
             answered
             |> QuestionLedger.from_interview()
             |> Map.fetch!(:blocks)
             |> List.first()
             |> Map.fetch!(:id)

    assert pending_id == answered_id
  end

  test "filters internal router prompts from reasoning detail" do
    interview = %{
      dialogue: [
        %{role: :user, text: "Visible answer"},
        %{role: :main, text: "Output exactly one directive as the first line"},
        %{role: :mcp, text: "Visible question"}
      ]
    }

    assert %{blocks: [%{detail_lines: detail_lines}]} = QuestionLedger.from_interview(interview)
    refute {"Reason", "Output exactly one directive as the first line"} in detail_lines
  end
end
