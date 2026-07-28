defmodule Ourocode.Terminal.HudModelTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.HudModel

  test "projects idle composer affordances without runtime noise" do
    hud = HudModel.build(%{"runtime" => "?", "status" => "healthy"}, [], :normal, %{}, 100)

    assert hud.mode_chip == "main"
    assert hud.placeholder == "Ask, / command, or ooo auto/pm/run"
    assert hud.left_status == "ready"
    assert hud.actions =~ "/ commands"
    assert hud.actions =~ "ooo work"
    assert hud.center_status == ""
  end

  test "left status leads with the active model and its last-turn latency" do
    hud =
      HudModel.build(
        %{"runtime" => "?", "status" => "healthy"},
        [],
        :normal,
        %{model_status: "provider: codex  (ChatGPT)  model: gpt-5.3-codex · 1.2s"},
        100
      )

    assert hud.left_status == "provider: codex  (ChatGPT)  model: gpt-5.3-codex · 1.2s   ready"
  end

  test "model status is omitted when absent so the strip stays compact" do
    hud = HudModel.build(%{"runtime" => "?", "status" => "healthy"}, [], :normal, %{}, 100)
    refute hud.left_status =~ "·"
  end

  test "projects workflow and MCP state as a compact operator strip" do
    sections = runtime_sections()

    workflow = %{
      latest_run_id: "run-1",
      runs: %{
        "run-1" => %{
          adapter_route: :run,
          status: :dispatching,
          model_profile: %{
            label: "execute/codex",
            model_label: "codex  (ChatGPT)"
          }
        }
      }
    }

    hud =
      HudModel.build(
        %{"runtime" => "ready"},
        sections,
        :normal,
        %{
          workflow: workflow,
          runtime_split: %{
            active?: true,
            parent_lines: ["MCP toolcall ouroboros__ralph · active · 2 child panes"],
            child_lines: [
              %{text: "Child session-a · active · parent=call-1"},
              %{id: "block-1", text: "+ tool call", style: :p_dim}
            ],
            block_ids: ["block-1"]
          }
        },
        120
      )

    assert hud.mode_chip == "mcp"
    assert hud.placeholder =~ "inspect MCP output"
    assert hud.placeholder =~ "Up/Dn, j/k"
    assert hud.center_status =~ "run"
    assert hud.center_status =~ "exec"
    assert hud.center_status =~ "Execute · Codex Runtime"
    assert hud.center_status =~ "evidence recorded"
    assert hud.center_status =~ "mcp"
    assert hud.center_status =~ "session-a active"
    assert hud.center_status =~ "1 parent"
    assert hud.center_status =~ "1 pane"
    assert hud.center_status =~ "1 block"
    assert hud.actions =~ "Up/Dn move"
    assert hud.actions =~ "Enter open"
  end

  test "keeps the full flow skeleton on narrow terminals" do
    hud =
      HudModel.build(
        %{"runtime" => "ready"},
        runtime_sections(),
        :normal,
        %{workflow: %{}, interview_reasoning: ["ambiguity 0.12"]},
        70
      )

    assert hud.center_status =~ "run socratic*"
    assert hud.center_status =~ "plan"
    assert hud.center_status =~ "exec*"
    assert hud.center_status =~ "verify*"
    assert hud.center_status =~ "evidence*"
  end

  test "prioritizes attention child status over the first MCP child" do
    hud =
      HudModel.build(
        %{"runtime" => "ready"},
        [],
        :normal,
        %{
          runtime_split: %{
            active?: true,
            parent_lines: ["MCP toolcall run · active · 2 child panes"],
            child_lines: [
              %{text: "Child session-a · completed · parent=call-1"},
              %{text: "Child session-b · failed · parent=call-1"}
            ],
            block_ids: ["block-1"]
          }
        },
        120
      )

    assert hud.center_status =~ "session-b failed"
    refute hud.center_status =~ "session-a completed"
  end

  test "prioritizes pending interview decisions over generic hints" do
    hud =
      HudModel.build(
        %{"runtime" => "ready"},
        [],
        :normal,
        %{
          interview_decision: true,
          interview_reasoning: ["because scope matters"],
          question_summary: "Q 2/5 · pending 1"
        },
        100
      )

    assert hud.mode_chip == "question"
    assert hud.placeholder == ""
    assert hud.center_status =~ "Q 2/5"
    assert hud.center_status =~ "pending 1"
    assert hud.actions =~ "Enter answer"
    assert hud.actions =~ "Tab reasoning"
  end

  test "notifications override action hints but keep state summary" do
    hud =
      HudModel.build(
        %{"runtime" => "ready"},
        [],
        :normal,
        %{notifications: ["Esc again to clear input"], workflow: %{latest_run_id: "run"}},
        100
      )

    assert hud.actions == "Esc again to clear input"
    assert hud.notification == "Esc again to clear input"
    assert hud.center_status =~ "run ready"
  end

  defp runtime_sections do
    [
      {"Parent/Child Sessions",
       [
         "parent MCP toolcall ouroboros__ralph · streaming · 2 child panes",
         "child session-a · working · parent=parent-1",
         "  + [streaming] Tool ouroboros__evolve_step arguments",
         "child session-b · completed · parent=parent-1",
         "  + [completed] Tool ouroboros__qa QA passed",
         "evidence receipt recorded"
       ]}
    ]
  end
end
