defmodule Ourocode.Terminal.InterviewPanel.DialogueTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.InterviewPanel.Dialogue

  test "formats visible dialogue turns with role styles and separators" do
    state = %{
      dialogue: [
        %{role: :mcp, text: "Second question"},
        %{role: :user, text: "First answer"}
      ]
    }

    assert Dialogue.rows(state, false) == [
             {"Answer  First answer", :strong},
             :rule,
             {"Question  Second question", :warn}
           ]
  end

  test "drops trailing MCP turn when requested" do
    state = %{
      dialogue: [
        %{role: :mcp, text: "Follow-up pending"},
        %{role: :user, text: "Known answer"}
      ]
    }

    assert Dialogue.rows(state, true) == [{"Answer  Known answer", :strong}]
  end

  test "does not label completion notices as questions" do
    state = %{
      dialogue: [
        %{role: :mcp, text: "AI interview fallback complete - run ooo seed when ready"},
        %{role: :user, text: "Accounts and sharing"}
      ]
    }

    assert Dialogue.rows(state, false) == [{"Answer  Accounts and sharing", :strong}]
  end

  test "filters leaked internal router prompts from main dialogue" do
    state = %{
      dialogue: [
        %{role: :user, text: "Visible"},
        %{role: :main, text: "Answer are the answerer/router half\nTool protocol"}
      ]
    }

    assert Dialogue.rows(state, false) == [{"Answer  Visible", :strong}]
  end

  test "labels workflow commands as goals instead of answers" do
    state = %{
      dialogue: [
        %{role: :user, text: "ooo pm build onboarding"}
      ]
    }

    assert Dialogue.rows(state, false) == [{"Goal  ooo pm build onboarding", :strong}]
  end

  test "keeps only the most recent dialogue turns from newest-first state" do
    state = %{
      dialogue:
        Enum.map(1..8, fn index ->
          %{role: :user, text: "Turn #{index}"}
        end)
    }

    assert Dialogue.rows(state, false) == [
             {"Answer  Turn 6", :strong},
             :rule,
             {"Answer  Turn 5", :strong},
             :rule,
             {"Answer  Turn 4", :strong},
             :rule,
             {"Answer  Turn 3", :strong},
             :rule,
             {"Answer  Turn 2", :strong},
             :rule,
             {"Answer  Turn 1", :strong}
           ]
  end
end
