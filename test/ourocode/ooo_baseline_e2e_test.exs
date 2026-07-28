defmodule Ourocode.OooBaselineE2ETest do
  @moduledoc """
  Interactive-loop E2E for the seed baseline scenario: an `ooo` workflow drives
  the real prompt loop with live runtime bindings attached, MCP events are
  drained by the loop poller, panes reflect the stream, a wonderTool checkpoint
  surfaces, and the Ouroboros capability graph is absorbed into the merged
  registry — all without a network server and without crashing the loop.

  This complements `BaselineEndToEndTest` (pipeline modules) by exercising the
  `EventLoop.run` + `LoopBindings` integration the terminal app actually uses.
  """

  use ExUnit.Case, async: false

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.Runtime.{Application, LoopBindings}
  alias Ourocode.Terminal.EventLoop

  setup do
    {:ok, runtime} =
      Application.bootstrap(%{project_dir: File.cwd!(), config: Ourocode.Config.defaults()})

    on_exit(fn -> Application.stop(runtime) end)
    %{runtime: runtime}
  end

  test "ooo baseline drives the loop: panes, wonderTool, capability, no crash", %{
    runtime: runtime
  } do
    {:ok, agent, binding_options} =
      LoopBindings.attach(%{status: :healthy, runtime: runtime})

    parent_call_id = "parent-e2e-1"

    # Synthetic interview stream (transport-neutral; same path a real relay uses).
    LoopBindings.enqueue(
      agent,
      LifecycleEvent.new(:parent_call_started, %{
        event_seq: 1,
        transport: :streamable_http,
        parent_call_id: parent_call_id,
        runtime_source: "ouroboros",
        external_ids: %{session_id: "session-e2e-1"},
        occurred_at_ms: 1_000,
        request_id: "req-e2e",
        method: "tools/call"
      })
    )

    LoopBindings.enqueue(agent, %{
      type: :child_event,
      source: :ouroboros,
      payload: %{
        "tool" => "wonderTool",
        "child_id" => "child-e2e-1",
        "parent_call_id" => parent_call_id,
        "questions" => [
          %{
            "id" => "transport",
            "header" => "Transport",
            "question" => "Which MCP transport should the interview prioritize?",
            "options" => [
              %{"label" => "stdio", "description" => "local pipe"},
              %{"label" => "streamable HTTP", "description" => "remote stream"}
            ]
          }
        ]
      }
    })

    {:ok, _capability} =
      LoopBindings.ingest_capabilities(runtime, [
        %{"name" => "ouroboros_interview", "description" => "Socratic interview"},
        %{"name" => "ouroboros_seed", "description" => "Generate a Seed"}
      ])

    {:ok, output} = StringIO.open("")

    options =
      binding_options
      |> Keyword.put(:read_line, fn _prompt -> :eof end)
      |> Keyword.put(:output, output)

    # The loop drains all queued runtime events, then exits cleanly on EOF.
    assert {:ok, result} =
             EventLoop.run(%{status: :healthy, runtime: runtime}, options)

    assert result.status == :input_eof
    assert length(result.runtime_events) >= 2

    snapshot = LoopBindings.pane_snapshot(agent)

    # Parent MCP pane is live with a stable id.
    assert [%{} | _] = snapshot.runtime.parent_panes.working
    rendered = Ourocode.Dashboard.ParentMcpPane.render(snapshot.runtime.parent_panes)
    assert [%{line: line} | _] = rendered.working
    assert line =~ "parent=#{parent_call_id}"

    # wonderTool checkpoint surfaced from the stream.
    assert %{tool: :wonder_tool, question_count: 1} = snapshot.wonder_tool

    # Answer routes back and closes the checkpoint.
    assert {:ok, decision} = LoopBindings.answer_wonder(agent, 2)
    assert decision.selected_label == "streamable HTTP"
    assert LoopBindings.pane_snapshot(agent).wonder_tool == nil

    # Capability graph is in the merged registry as dynamic-skill entries.
    {:ok, registry} = Application.current_command_registry(runtime)
    assert :dynamic_skill in Map.get(registry, :sources, [])
    assert inspect(registry, limit: :infinity) =~ "ouroboros_interview"
  end

  test "unavailable MCP server opens a visible local interview fallback", %{
    runtime: runtime
  } do
    previous_autostart = System.get_env("OUROCODE_MCP_AUTOSTART")
    System.put_env("OUROCODE_MCP_AUTOSTART", "0")

    on_exit(fn ->
      if previous_autostart,
        do: System.put_env("OUROCODE_MCP_AUTOSTART", previous_autostart),
        else: System.delete_env("OUROCODE_MCP_AUTOSTART")
    end)

    {:ok, agent, binding_options} =
      LoopBindings.attach(%{status: :healthy, runtime: runtime})

    task_request = %Ourocode.TaskRequest{
      id: "e2e-fail-1",
      task_input: "ooo interview clarify the MCP UI",
      routing_decision: %{
        execution_route: :ouroboros_workflow,
        runtime_source: :ouroboros,
        transport: :streamable_http,
        adapter_route: :interview
      }
    }

    on_prompt_input = Keyword.fetch!(binding_options, :on_prompt_input)

    input_event = %{active_model: scripted_interview_model()}

    assert :ok == on_prompt_input.(task_request, input_event, %{status: :healthy})

    snapshot =
      Enum.reduce_while(1..400, nil, fn _i, _acc ->
        snapshot = LoopBindings.pane_snapshot(agent)
        question = get_in(snapshot, [:interview, :question])
        options = get_in(snapshot, [:interview, :question_options]) || []

        if is_binary(question) and String.trim(question) != "" and String.contains?(question, "?") and
             length(options) >= 2 do
          {:halt, snapshot}
        else
          Process.sleep(50)
          {:cont, nil}
        end
      end)

    assert snapshot, "local fallback did not surface a visible interview question"

    assert %{
             interview: %{
               question: question,
               question_options: [_first | _rest] = options,
               status: "waiting for your answer"
             },
             wonder_tool: %{question_count: 1} = wonder_tool
           } = snapshot

    assert length(options) >= 2
    assert [%{question: ^question} | _rest] = get_in(wonder_tool, [:request, :questions])
  end

  defp scripted_interview_model do
    %Ourocode.Model{
      id: :codex,
      label: "codex  (test)",
      kind: :oauth,
      status: :ready,
      run: fn prompt, _opts, on_chunk ->
        question =
          if String.contains?(prompt, "MCP UI"),
            do: "What should the MCP UI clarify first?",
            else: "What should this interview clarify first?"

        output = """
        ASK_USER #{question}
        - User flow | Clarify the path a user should complete
        - Success signal | Define what proves the UI works
        """

        on_chunk.(output)
        {:ok, output}
      end
    }
  end
end
