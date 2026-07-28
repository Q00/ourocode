defmodule Ourocode.Terminal.InterviewPanelTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.InterviewPanel

  defp detection(questions) do
    %{
      request_id: "req-1",
      request: %{tool: :wonder_tool, type: :multiple_choice_decision, questions: questions}
    }
  end

  defp option(label, desc, recommended? \\ false) do
    %{label: label, description: desc, recommended?: recommended?}
  end

  test "interview block renders an active wonder picker with multi-question controls" do
    det =
      detection([
        %{
          header: "Scope",
          question: "Which scope should we take?",
          options: [option("small", "one module", true), option("broad", "whole app")]
        },
        %{
          header: "Evidence",
          question: "What proof is required?",
          options: [option("tests", "focused checks"), option("audit", "manual review")]
        }
      ])

    nav = %{qidx: 0, picks: %{0 => 1, 1 => 0}}

    assert {"INTERVIEW", lines, hint} =
             InterviewPanel.interview_block_lines(%{wonder_tool: det}, nav, 0)

    assert Enum.at(lines, 0) =~ "Question 1/2"
    assert ">> [2] broad - whole app" in lines

    assert hint == "Tab switches question"
  end

  test "interview block falls back to free text when wonder request is incomplete" do
    result = %{
      wonder_tool: %{request_id: "bad-wt", request: %{"questions" => []}},
      interview: %{
        question: "Which scope should we inspect first?",
        status: "waiting for your answer"
      }
    }

    assert {"INTERVIEW", lines, ""} =
             InterviewPanel.interview_block_lines(result, nil, 0)

    assert "Which scope should we inspect first?" in lines
    assert ">> [Custom answer] type any text, then Enter" in lines
  end

  test "interview block renders dialogue and dim working status for plain interview state" do
    result = %{
      interview: %{
        dialogue: [
          %{role: :user, text: "Plugin dispatch"},
          %{role: :mcp, text: "Which workflow matters most?"}
        ],
        router: ["TOOL grep"]
      }
    }

    assert {"INTERVIEW", lines, "plain answer"} =
             InterviewPanel.interview_block_lines(result, nil, 0)

    assert {"Question  Which workflow matters most?", :warn} in lines
    assert {"Answer  Plugin dispatch", :strong} in lines
    assert :rule in lines
    assert {"■⬝⬝ main session is checking project context", :dim} in lines
  end

  test "interview block clears after user-cancelled completion" do
    result = %{
      interview: %{
        complete: :user_done,
        mcp_activity: ["activity: stale"],
        question: "Which workflow matters most?",
        question_options: [
          %{label: "Plugins", description: "Focus plugin dispatch"},
          %{label: "Runtime", description: "Focus runtime state"}
        ],
        status: "waiting for your answer"
      }
    }

    assert InterviewPanel.interview_block_lines(result, nil, 0) == nil
    assert InterviewPanel.interview_reasoning_lines(result, 0) == []
    assert InterviewPanel.mcp_activity_lines(result) == []
  end

  test "completed local preview does not keep router trace spinner running" do
    result = %{
      interview: %{
        complete: :local_preview,
        status: "interview complete: local_preview",
        router: ["MCP daemon unavailable; using local PM interview fallback"],
        dialogue: [
          %{role: :mcp, text: "local interview fallback complete - run ooo seed when ready"},
          %{role: :user, text: "Accounts and sharing"}
        ]
      }
    }

    assert InterviewPanel.interview_working_lines(result, 0) == []
    assert {_, lines, _} = InterviewPanel.interview_block_lines(result, nil, 0)

    refute Enum.any?(lines, fn
             {line, _style} -> String.contains?(line, "MCP daemon unavailable")
             line when is_binary(line) -> String.contains?(line, "MCP daemon unavailable")
             :rule -> false
           end)
  end

  test "interview block strips MCP session preamble from dialogue rows" do
    result = %{
      interview: %{
        dialogue: [
          %{
            role: :mcp,
            text:
              "MCP Interview started. Session ID: interview20260526153956 What should we validate?"
          }
        ]
      }
    }

    assert {"INTERVIEW", lines, _hint} = InterviewPanel.interview_block_lines(result, nil, 0)

    assert {"Question  What should we validate?", :warn} in lines

    refute Enum.any?(lines, fn
             {line, _style} ->
               line =~ "MCP Interview started" or line =~ "Session ID:" or
                 line =~ "Session interview"

             line when is_binary(line) ->
               line =~ "MCP Interview started" or line =~ "Session ID:" or
                 line =~ "Session interview"

             :rule ->
               false
           end)
  end

  test "interview block renders stored question options as a picker" do
    result = %{
      interview: %{
        question: "Which first user outcome matters most?",
        question_options: [
          %{label: "Quality", description: "Raise reliability first"},
          %{label: "Speed", description: "Optimize turnaround first"}
        ],
        status: "waiting for your answer"
      }
    }

    assert {"INTERVIEW", lines, ""} =
             InterviewPanel.interview_block_lines(result, nil, 0)

    assert "Which first user outcome matters most?" in lines
    assert ">> [1] Quality - Raise reliability first" in lines
    assert "   [2] Speed - Optimize turnaround first" in lines

    refute Enum.any?(lines, fn
             {line, _style} -> line =~ "question ready"
             line when is_binary(line) -> line =~ "question ready"
             :rule -> false
           end)
  end

  test "interview block does not synthesize a picker as soon as a question is ready" do
    result = %{
      interview: %{
        dialogue: [
          %{
            role: :mcp,
            text:
              "What outcome should validate plugin install flow produce: a testable requirements seed, or an investigation checklist?"
          },
          %{role: :user, text: "validate plugin install flow"}
        ],
        question:
          "What outcome should validate plugin install flow produce: a testable requirements seed, or an investigation checklist?",
        status: "waiting for your answer",
        router: ["PATH"]
      }
    }

    assert {"INTERVIEW", lines, ""} =
             InterviewPanel.interview_block_lines(result, nil, 12)

    text =
      Enum.map_join(lines, "\n", fn
        {line, _style} -> line
        :rule -> "----"
        line -> line
      end)

    assert text =~ "What outcome should validate plugin install flow produce"
    refute text =~ ">> [1] a testable requirements seed"
    refute text =~ "   [2] an investigation checklist"
    assert text =~ ">> [Custom answer] type any text, then Enter"
    refute text =~ "Answer  validate plugin install flow"
    refute text =~ "Question  What outcome"
    refute text =~ "preparing interview question"
  end

  test "interview block keeps previous question ledger above active picker" do
    result = %{
      interview: %{
        dialogue: [
          %{role: :mcp, text: "Current question"},
          %{role: :user, text: "First answer"},
          %{role: :mcp, text: "First question"}
        ],
        question: "Current question",
        question_options: [
          %{label: "Current option", description: "Answer the active prompt"}
        ],
        status: "waiting for your answer"
      }
    }

    assert {"INTERVIEW", lines, ""} =
             InterviewPanel.interview_block_lines(result, nil, 0)

    text =
      Enum.map_join(lines, "\n", fn
        {line, _style} -> line
        :rule -> "----"
        line -> line
      end)

    assert text =~ "- [answered] Q1 First question"
    assert text =~ "Answer  First answer"
    assert text =~ "Current question"
    assert text =~ ">> [1] Current option - Answer the active prompt"
    refute text =~ "[pending] Q"
    refute text =~ "[pending] Q2 Current question"
  end

  test "interview block hides stale options after the current question is answered" do
    result = %{
      interview: %{
        dialogue: [
          %{role: :user, text: "End-to-end install succeeds"},
          %{role: :mcp, text: "Which proof matters most?"},
          %{role: :user, text: "validate plugin install flow"}
        ],
        question: "Which proof matters most?",
        question_options: [
          %{label: "Install success", description: "Run a real plugin install"},
          %{label: "Failure diagnostics", description: "Check bad plugin output"}
        ],
        router: []
      }
    }

    assert {"INTERVIEW", lines, "plain answer"} =
             InterviewPanel.interview_block_lines(result, nil, 0)

    text =
      Enum.map_join(lines, "\n", fn
        {line, _style} -> line
        :rule -> "----"
        line -> line
      end)

    assert text =~ "Question  Which proof matters most?"
    assert text =~ "Answer  End-to-end install succeeds"
    refute text =~ ">> [1] Install success"
    refute text =~ "[Free answer]"
  end

  test "answered waiting state keeps context without rendering stale choices" do
    result = %{
      interview: %{
        waiting: true,
        status: "preparing next interview question",
        question: "",
        last_answered_question: "Which proof matters most?",
        last_answer: "Run the verifier",
        last_question_options: [
          %{label: "Health checks", description: "Run the local checks"}
        ],
        waiting_started_monotonic_ms: System.monotonic_time(:millisecond) - 3_000
      }
    }

    assert {"INTERVIEW", lines, "plain answer"} =
             InterviewPanel.interview_block_lines(result, nil, 2)

    text =
      Enum.map_join(lines, "\n", fn
        {line, _style} -> line
        :rule -> "----"
        line -> line
      end)

    assert text =~ "Round accepted"
    assert text =~ "Question  Which proof matters most?"
    assert text =~ "Answer    Run the verifier"
    assert text =~ "Next      answer sent; generating choices"
    assert text =~ "building next answer choices"
    assert text =~ "No input needed; choices will appear automatically"
    refute text =~ ">> [1] Health checks"
    refute text =~ "[Custom answer]"
  end

  test "answered waiting state distinguishes opening the interview session" do
    result = %{
      interview: %{
        waiting: true,
        status: "opening interview session to send answer",
        question: "",
        last_answered_question: "What outcome should this PM interview produce?",
        last_answer: "Define the target user",
        waiting_started_monotonic_ms: System.monotonic_time(:millisecond) - 1_000
      }
    }

    assert {"INTERVIEW", lines, _hint} = InterviewPanel.interview_block_lines(result, nil, 1)

    text =
      Enum.map_join(lines, "\n", fn
        {line, _style} -> line
        :rule -> "----"
        line -> line
      end)

    assert text =~ "Next      opening interview session"
    assert text =~ "opening the interview session - choices will appear here"
    refute text =~ "building next answer choices"
  end

  test "interview block fails closed to the current question when dialogue is malformed" do
    result = %{
      interview: %{
        dialogue: [:malformed_turn],
        question: "Which first user outcome should this interview clarify?",
        status: "waiting for your answer"
      }
    }

    assert {"INTERVIEW", lines, ""} =
             InterviewPanel.interview_block_lines(result, nil, 0)

    assert "Which first user outcome should this interview clarify?" in lines
    assert ">> [Custom answer] type any text, then Enter" in lines
  end

  test "interview block renders sticky live session hints while no question is pending" do
    running = %{
      interview_session: %{label: "ooo interview plugin dispatch"},
      paused: false
    }

    assert {"INTERVIEW", ["ooo interview plugin dispatch", {activity, :dim}], hint} =
             InterviewPanel.interview_block_lines(running, nil, 1)

    assert activity =~ "■■⬝ building the first question"
    assert hint == "drafting question"

    paused = %{running | paused: true}

    assert {"INTERVIEW (paused)", ["ooo interview plugin dispatch"], paused_hint} =
             InterviewPanel.interview_block_lines(paused, nil, 1)

    assert paused_hint == "paused   /answer <answer> resumes   /cancel stops interview"
  end

  test "interview block does not synthesize generic options before a question exists" do
    result = %{
      interview: %{
        dialogue: [%{role: :user, text: "ooo interview validate plugin install flow"}],
        question: "",
        status: "waiting for MCP interview question",
        waiting: true
      }
    }

    assert {"INTERVIEW", lines, "plain answer"} =
             InterviewPanel.interview_block_lines(result, nil, 24)

    text =
      Enum.map_join(lines, "\n", fn
        {line, _style} -> line
        :rule -> "----"
        line -> line
      end)

    assert text =~ "Goal  ooo interview validate plugin install flow"
    assert text =~ "■⬝⬝ building the first question"
    refute text =~ "Answer in my own words"
    refute text =~ "[Free answer]"
  end

  test "delayed interview preparation shows explicit waiting actions without fake options" do
    result = %{
      interview: %{
        dialogue: [%{role: :user, text: "ooo interview validate plugin install flow"}],
        question: "",
        status: "waiting for MCP interview question",
        waiting: true,
        waiting_started_monotonic_ms: System.monotonic_time(:millisecond) - 7_000
      }
    }

    assert {"INTERVIEW", lines, "plain answer"} =
             InterviewPanel.interview_block_lines(result, nil, 24)

    text =
      Enum.map_join(lines, "\n", fn
        {line, _style} -> line
        :rule -> "----"
        line -> line
      end)

    assert text =~ "No input needed; choices will appear automatically"
    assert text =~ "Esc pauses so you can add context"
    assert text =~ "/cancel stops this interview"
    refute text =~ "[1]"
    refute text =~ "[Free answer]"
  end

  test "long delayed interview preparation shows retry guidance without implying Enter helps" do
    result = %{
      interview: %{
        dialogue: [%{role: :user, text: "ooo pm plan plugin setup"}],
        question: "",
        status: "waiting for MCP follow-up question",
        waiting: true,
        waiting_started_monotonic_ms: System.monotonic_time(:millisecond) - 16_000
      }
    }

    assert {"INTERVIEW", lines, "plain answer"} =
             InterviewPanel.interview_block_lines(result, nil, 60)

    text =
      Enum.map_join(lines, "\n", fn
        {line, _style} -> line
        :rule -> "----"
        line -> line
      end)

    assert text =~ "still building choices"
    assert text =~ "No input needed; choices will appear automatically"
    assert text =~ "/cancel stops; submit the same command to retry"
    refute text =~ "Enter waits for choices"
  end

  test "server error state does not render stale working guidance" do
    result = %{
      interview: %{
        dialogue: [%{role: :user, text: "ooo interview build slides"}],
        question: "",
        status:
          "MCP question generator unavailable: Question generation failed: Error loading config.toml",
        waiting: false,
        resumable: true,
        session_id: "interview-1"
      }
    }

    assert {"INTERVIEW", lines, _hint} = InterviewPanel.interview_block_lines(result, nil, 80)

    text =
      Enum.map_join(lines, "\n", fn
        {line, _style} -> line
        :rule -> "----"
        line -> line
      end)

    assert text =~ "MCP question generator unavailable"
    assert text =~ "Session  interview-1 resume available"
    refute text =~ "still building choices"
    refute text =~ "working, not stuck"
    refute text =~ "No input needed; choices will appear automatically"
  end

  test "interview block does not show preparation status once a question is ready" do
    result = %{
      pane_snapshot: fn ->
        %{
          interview: %{
            question: "Which setup step should the interview clarify?",
            question_options: [
              %{label: "Setup docs", description: "Clarify first-run setup"}
            ],
            status: "waiting for your answer",
            waiting: false,
            waiting_started_monotonic_ms: System.monotonic_time(:millisecond) - 20_000,
            router: ["PATH"]
          },
          paused: false
        }
      end
    }

    assert InterviewPanel.interview_working_lines(result, 0) == []

    assert {"INTERVIEW", lines, _hint} = InterviewPanel.interview_block_lines(result, nil, 0)

    text =
      Enum.map_join(lines, "\n", fn
        {line, _style} -> line
        :rule -> "----"
        line -> line
      end)

    refute text =~ "still building choices"
    refute text =~ "building answer choices"
  end
end
