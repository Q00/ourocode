defmodule Ourocode.Terminal.TuiRuntimeSplitTest do
  @moduledoc """
  When a runtime workflow is live, the body splits into a scrollable
  conversation transcript on the left and MCP internals (parent workflow on
  top, child session stream on the bottom) on the right. With no live panes
  the calm single transcript stays.
  """

  use ExUnit.Case, async: true

  alias Ourocode.Terminal.Tui

  @idle_frame """
  +-- ourocode terminal region=header_status x=0 y=0 w=88 h=5
  | app=ourocode status=healthy runtime=ready session=terminal-1
  +--
  +-- Parent/Child Sessions region=runtime_panes layout=terminal_split
  | [parent-region] x=0 y=0 w=80 h=8
  | parent empty
  | [child-region] x=0 y=9 w=80 h=12
  | child empty
  +--
  +-- State
  | surface=terminal focus=task_prompt layout=compact
  | runtime=ready stream=streaming journal=ready
  | queued=0 replayable?=false transports=stdio,sse,streamable_http
  +--
  """

  @live_frame """
  +-- ourocode terminal region=header_status x=0 y=0 w=88 h=5
  | app=ourocode status=healthy runtime=ready session=terminal-1
  +--
  +-- Parent/Child Sessions region=runtime_panes layout=terminal_split
  | [parent-region] x=0 y=0 w=80 h=8
  | parent parent=parent-1 transport=streamable_http status=streaming
  | [child-region] x=0 y=9 w=80 h=12
  | child child=child-1 token=interview-question-1
  +--
  +-- State
  | surface=terminal focus=task_prompt layout=compact
  | runtime=ready stream=streaming journal=ready
  | queued=0 replayable?=false transports=stdio,sse,streamable_http
  +--
  """

  defp render(frame, activity, scroll \\ 0) do
    Tui.frame_lines(frame, activity, "", 100, 24, %{scroll: scroll})
    |> Enum.join("\n")
  end

  test "idle frame stays a single calm transcript (no split)" do
    text = render(@idle_frame, ["you> hi", "ourocode> hello there"])

    refute text =~ "MCP parent"
    refute text =~ "child stream"
    assert text =~ "hello there"
  end

  test "live workflow splits transcript left, MCP parent/child right" do
    text = render(@live_frame, ["you> ooo interview", "ourocode> dispatching"])

    # Right side shows MCP internals, parent on top, child stream below.
    assert text =~ "MCP parent"
    assert text =~ "child stream"
    assert text =~ "parent-1"
    assert text =~ "child=child-1"

    # Left side still carries the conversation transcript.
    assert text =~ "dispatching"

    # The vertical separator proves a real two-column split, not inlined text.
    assert text =~ "|"
  end

  test "interview renders as a pinned left block (not a modal) + right reasoning" do
    block =
      {"INTERVIEW",
       [
         "Which MCP transport should the interview prioritize?",
         "1. stdio - local process pipe",
         "2. streamable HTTP - remote streaming"
       ], "type answer   /cancel decline   Esc pause"}

    reasoning = ["ambiguity 0.42", "milestone scope", "seed-ready: no"]

    text =
      Tui.frame_lines(@live_frame, ["you> ooo interview"], "", 100, 24, %{
        interview_block: block,
        interview_reasoning: reasoning
      })
      |> Enum.join("\n")

    # No modal box; the question is a prominent left-column block.
    refute text =~ "+- wonderTool"
    assert text =~ "INTERVIEW"
    assert text =~ "Which MCP transport should the interview prioritize?"
    assert text =~ "type answer"

    # The "why this question" reasoning is on the right.
    assert text =~ "interview"
    assert text =~ "ambiguity 0.42"
    assert text =~ "milestone scope"
  end

  test "a long interview block uses the left column without shrinking the right panel" do
    long_question =
      "right panel에서 구체적으로 어떤 순간이 거칠거나 뚝뚝 끊긴다고 느껴지는지 " <>
        "패널 전환, 스트리밍 텍스트, 스크롤, 색상 질감까지 구체적으로 알려주세요 끝문장"

    block =
      {"INTERVIEW",
       [
         "Interview",
         long_question,
         ">> [1] panel transition - 전환이 갑작스럽다",
         "   [2] streaming - 텍스트가 점프한다"
       ], "Up/Dn pick   1-9 shortcut   Enter submit   type answer   /cancel decline   Esc pause"}

    plain =
      Tui.frame_lines(@live_frame, ["you> ooo interview"], "", 120, 30, %{})

    with_block =
      Tui.frame_lines(@live_frame, ["you> ooo interview"], "", 120, 30, %{
        interview_block: block,
        interview_reasoning: ["waiting for your answer"]
      })

    assert Enum.join(with_block, "\n") =~ "끝문장"
    assert Enum.join(with_block, "\n") =~ ">> [1] panel transition"

    assert line_index(plain, "MCP parent") == line_index(with_block, "interview live")
  end

  test "active wonder picker focuses the decision and hides the right pane" do
    block =
      {"INTERVIEW",
       [
         "UX checkpoint",
         "Which behavior should change first?",
         ">> [1] Arrow navigation - selection should move",
         "   [2] Visual focus - dim everything else"
       ], "Up/Dn pick   1-9 shortcut   Enter submit   type answer   /cancel decline   Esc pause"}

    text =
      Tui.frame_lines(@live_frame, ["you> ooo interview"], "custom thought", 100, 24, %{
        interview_block: block,
        interview_reasoning: ["ambiguity 0.42"],
        wonder_focus: true
      })
      |> Enum.join("\n")

    assert text =~ "INTERVIEW"
    assert text =~ ">> [1] Arrow navigation"
    assert text =~ "Free answer: custom thought"
    assert text =~ "Esc main session"
    refute text =~ "MCP parent"
    refute text =~ "child stream"
  end

  test "right column is MCP-internal only; router/reasoning live in the LEFT block" do
    interview = %{
      ambiguity: 0.42,
      milestone: "scope",
      seed_ready: true,
      complete: :seed_ready,
      session_id: "interview_x",
      router: ["ANSWER [code]: Elixir 1.15 escript CLI (mix.exs)", "TOOL READ mix.exs"],
      reasoning: ["the project is Elixir; this is a code-answerable fact", "older chunk"]
    }

    result = %{pane_snapshot: fn -> %{interview: interview, paused: false} end}

    right = Tui.interview_reasoning_lines(result)
    left = Tui.interview_working_lines(result, 0)

    # Right = MCP-internal wire facts only.
    assert "ambiguity 0.42" in right
    assert "seed-ready: yes" in right
    assert "interview complete: seed_ready" in right
    assert "session interview_x" in right
    refute Enum.any?(right, &(&1 =~ "ANSWER" or &1 =~ "TOOL" or &1 =~ "code-answerable"))

    # Left = an animated activity line carrying ONLY the latest clean router
    # trace; the raw streamed reasoning never leaks here.
    assert [activity] = left
    assert activity =~ "main session answered: Elixir 1.15 escript CLI (mix.exs)"
    refute activity =~ "ANSWER"
    refute activity =~ "code-answerable fact"
    refute activity =~ "older chunk"
    refute activity =~ "TOOL READ mix.exs"
  end

  test "right column prefers MCP-provided internal reasoning lines" do
    interview = %{
      ambiguity: 0.31,
      milestone: "scope",
      seed_ready: false,
      session_id: "interview_meta",
      mcp_reasoning: [
        "phase: answer",
        "rounds: 1 answered / 2 total",
        "next: ask user to answer pending question"
      ]
    }

    result = %{pane_snapshot: fn -> %{interview: interview, paused: false} end}

    right = Tui.interview_reasoning_lines(result)

    assert "phase: answer" in right
    assert "rounds: 1 answered / 2 total" in right
    assert "next: ask user to answer pending question" in right

    refute "ambiguity 0.31" in right
    refute "milestone scope" in right
    refute "seed-ready: no" in right
  end

  test "active interview owns the left panel instead of duplicating activity below it" do
    block =
      {"INTERVIEW",
       [
         {"MCP   Which work should happen first?", :warn},
         {"YOU   Refactor/cleanup", :strong},
         {"MCP   What does cleanup mean here?", :warn}
       ], "type your answer + Enter   Esc pause"}

    text =
      Tui.frame_lines(
        @live_frame,
        [
          "[workflow-starting] dispatching_input task=task_1",
          "queued task task_1: ooo interview",
          "you> Refactor/cleanup",
          "you> General hygiene",
          "workflow resumed"
        ],
        "",
        100,
        24,
        %{
          interview_block: block,
          interview_reasoning: ["waiting for your answer"],
          interview_paused: false
        }
      )
      |> Enum.join("\n")

    assert text =~ "INTERVIEW"
    assert text =~ "MCP Which work should happen first?"
    assert text =~ "YOU Refactor/cleanup"
    assert text =~ "MCP parent"

    refute text =~ "workflow-starting"
    refute text =~ "queued task"
    refute text =~ "you> Refactor/cleanup"
    refute text =~ "you> General hygiene"
    refute text =~ "workflow resumed"
  end

  test "router ASK_USER protocol is not shown in the interview activity line" do
    result = %{
      pane_snapshot: fn ->
        %{
          interview: %{router: ["ASK_USER (4 opt): What should change next?"]},
          paused: false
        }
      end
    }

    assert [activity] = Tui.interview_working_lines(result, 0)
    assert activity =~ "question ready"
    refute activity =~ "ASK_USER"
    refute activity =~ "4 opt"
  end

  defp line_index(lines, pattern) do
    Enum.find_index(lines, &String.contains?(&1, pattern))
  end

  test "the activity line animates and stays clean when no trace yet" do
    result = %{pane_snapshot: fn -> %{interview: %{question: "q?"}, paused: false} end}

    a = Tui.interview_working_lines(result, 0)
    b = Tui.interview_working_lines(result, 1)

    assert [line_a] = a
    assert [line_b] = b
    assert line_a =~ "the main session is handling this"
    # Different tick -> different spinner frame (visibly not frozen).
    refute line_a == line_b
  end

  test "right interview status shows a visible spinner while waiting on MCP" do
    result = %{
      pane_snapshot: fn ->
        %{
          interview: %{waiting: true, status: "waiting for MCP interview question"},
          paused: false
        }
      end
    }

    assert ["| phase received - MCP is preparing the interview question"] =
             Tui.interview_reasoning_lines(result, 0)

    assert ["/ phase received - MCP is preparing the interview question"] =
             Tui.interview_reasoning_lines(result, 1)
  end

  test "a paused interview shows no spinner (the user is talking to main)" do
    result = %{pane_snapshot: fn -> %{interview: %{question: "q?"}, paused: true} end}
    assert Tui.interview_working_lines(result, 3) == []
  end

  test "right interview status does not keep spinning while paused" do
    result = %{
      pane_snapshot: fn ->
        %{
          interview: %{waiting: true, status: "waiting for MCP follow-up question"},
          paused: true
        }
      end
    }

    assert ["phase paused - discussing with main session"] =
             Tui.interview_reasoning_lines(result, 0)

    assert ["phase paused - discussing with main session"] =
             Tui.interview_reasoning_lines(result, 1)
  end

  test "paused interview explains how to submit a direct answer" do
    block =
      {"INTERVIEW (paused)",
       [
         "Interview",
         "What should change?"
       ], "type to talk to main   /answer <answer> submits to interview"}

    text =
      Tui.frame_lines(@live_frame, ["you> discuss first"], "", 100, 24, %{
        interview_block: block,
        interview_paused: true
      })
      |> Enum.join("\n")

    assert text =~ "/answer <answer> submits to interview"
    assert text =~ "type normally to discuss with main session"
  end

  test "paused interview transcript keeps the discussion near the checkpoint" do
    block =
      {"INTERVIEW (paused)", ["Interview", "What should change?"],
       "type to talk to main   /answer <answer> submits to interview"}

    text =
      Tui.frame_lines(
        @live_frame,
        [
          "empty",
          "[workflow-starting] dispatching_input task=task_1",
          "queued task task_1: ooo interview",
          "-- interview paused (type to talk to main session)",
          "-- model: codex",
          "status=healthy runtime=ready",
          "you> 한글로 얘기해줘",
          "ourocode> 네, 한글로 이야기하겠습니다.",
          "workflow resumed"
        ],
        "",
        100,
        24,
        %{
          interview_block: block,
          interview_paused: true
        }
      )
      |> Enum.join("\n")

    assert text =~ "한글로 얘기해줘"
    assert text =~ "한글로 이야기하겠습니다"
    refute text =~ "workflow-starting"
    refute text =~ "queued task"
    refute text =~ "interview paused (type to talk"
    refute text =~ "-- empty"
    refute text =~ "model: codex"
    refute text =~ "status=healthy"
    refute text =~ "workflow resumed"
  end

  test "the three-party dialogue is color-coded per speaker" do
    # Stored newest-first (as LoopBindings keeps it).
    dialogue = [
      %{role: :main, text: "[from-code] Elixir escript"},
      %{role: :mcp, text: "(ambiguity 0.42) which stack?"}
    ]

    result = %{pane_snapshot: fn -> %{interview: %{dialogue: dialogue}, paused: false} end}

    rows = Tui.dialogue_rows(result, false)

    # Oldest -> newest, each carrying an explicit speaker color.
    assert [{mcp_line, :warn}, {main_line, :ok}] = rows
    assert mcp_line == "MCP   (ambiguity 0.42) which stack?"
    assert main_line == "MAIN  [from-code] Elixir escript"
  end

  test "the open MCP question is dropped from history when the picker shows it" do
    dialogue = [
      %{role: :mcp, text: "(ambiguity 0.7) pick transport?"},
      %{role: :user, text: "stdio"},
      %{role: :mcp, text: "(ambiguity 0.5) earlier q"}
    ]

    result = %{pane_snapshot: fn -> %{interview: %{dialogue: dialogue}, paused: false} end}

    # drop_trailing_mcp?: the newest turn is :mcp (the open question the
    # picker renders), so it is not duplicated in the history rows.
    assert [{_q, :warn}, {you, :strong}] = Tui.dialogue_rows(result, true)
    assert you == "YOU   stdio"
    refute Tui.dialogue_rows(result, true) |> Enum.any?(fn {t, _} -> t =~ "pick transport?" end)

    # Without the drop it stays (plain/waiting state keeps the open question).
    assert Tui.dialogue_rows(result, false) |> List.last() |> elem(0) =~ "pick transport?"
  end

  test "scroll-back keeps older transcript reachable without truncation" do
    history = for n <- 1..40, do: "ourocode> line-#{n}"

    tail = render(@idle_frame, history, 0)
    assert tail =~ "line-40"
    refute tail =~ "line-1"

    # A large offset clamps to the top of history (full scroll-back).
    scrolled = render(@idle_frame, history, 1000)
    assert scrolled =~ "line-1"
  end
end
