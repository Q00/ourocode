defmodule Ourocode.Terminal.TuiSubmitTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{TuiState, TuiSubmit}

  setup do
    {:ok, output} = StringIO.open("")
    IO.write(output, "existing output\n")
    state = TuiState.start_link()

    on_exit(fn ->
      safe_close(output, &StringIO.close/1)
      safe_close(state, &Agent.stop/1)
    end)

    %{output: output, state: state}
  end

  test "handle opens provider picker for provider commands", %{output: output, state: state} do
    callbacks = callbacks(self())

    assert :continue = TuiSubmit.handle("/provider", %{}, output, state, 80, 24, callbacks)
    assert TuiState.mode(state) == :model
    assert TuiState.pidx(state) == 0
    assert_receive {:redraw, "", 80, 24}

    TuiState.put_mode(state, :normal)
    TuiState.put_pidx(state, 3)

    assert :continue = TuiSubmit.handle("/providers", %{}, output, state, 100, 30, callbacks)
    assert TuiState.mode(state) == :model
    assert TuiState.pidx(state) == 0
    assert_receive {:redraw, "", 100, 30}
  end

  test "handle leaves model commands on slash command dispatch", %{output: output, state: state} do
    callbacks = callbacks(self())
    TuiState.put_mode(state, :normal)
    TuiState.put_pidx(state, 3)

    for line <- ["/model", "/models", "/model bad"] do
      assert {:submit, ^line} = TuiSubmit.handle(line, %{}, output, state, 80, 24, callbacks)
      assert TuiState.mode(state) == :normal
      assert TuiState.pidx(state) == 3
      refute_received {:redraw, "", 80, 24}
    end
  end

  test "handle login still opens provider picker for auth selection", %{
    output: output,
    state: state
  } do
    callbacks = callbacks(self())
    TuiState.put_pidx(state, 5)

    assert :continue = TuiSubmit.handle("/login", %{}, output, state, 80, 24, callbacks)
    assert TuiState.mode(state) == :model
    assert TuiState.pidx(state) == 0
    assert_receive {:redraw, "", 80, 24}
  end

  test "handle returns slash and ooo submissions without chatting", %{
    output: output,
    state: state
  } do
    callbacks = callbacks(self())

    assert {:submit, "/status"} =
             TuiSubmit.handle("/status", %{}, output, state, 80, 24, callbacks)

    assert {:submit, "ooo run seed.md"} =
             TuiSubmit.handle("ooo run seed.md", %{}, output, state, 80, 24, callbacks)

    assert_receive {:redraw, "", 80, 24}
  end

  test "handle stores workspace model for management slash commands", %{
    output: output,
    state: state
  } do
    callbacks = callbacks(self())

    assert {:submit, "/sandbox"} =
             TuiSubmit.handle("/sandbox", %{}, output, state, 80, 24, callbacks)

    assert %{kind: "sandbox", selected: "control:writable-roots"} = TuiState.workspace(state)

    assert {:submit, "/agents"} =
             TuiSubmit.handle(
               "/agents",
               %{runtime: %{pane_model: %{panes: %{}}}},
               output,
               state,
               80,
               24,
               callbacks
             )

    assert %{kind: "agents", selected: "agent:ready:pm-interview"} = TuiState.workspace(state)
  end

  test "handle stores sessions and bare resume list workspaces", %{
    output: output,
    state: state
  } do
    callbacks = callbacks(self())

    assert {:submit, "/sessions"} =
             TuiSubmit.handle("/sessions", %{}, output, state, 80, 24, callbacks)

    assert %{kind: "sessions"} = TuiState.workspace(state)

    assert {:submit, "/resume"} =
             TuiSubmit.handle("/resume", %{}, output, state, 80, 24, callbacks)

    assert %{kind: "resume"} = TuiState.workspace(state)
  end

  test "handle does not replace resume action output with the list workspace", %{
    output: output,
    state: state
  } do
    callbacks = callbacks(self())
    TuiState.put_workspace(state, %{kind: "resume", records: []})

    assert {:submit, "/resume 1"} =
             TuiSubmit.handle("/resume 1", %{}, output, state, 80, 24, callbacks)

    assert TuiState.workspace(state) == nil
  end

  test "handle stores startup workspace for ooo workflows", %{output: output, state: state} do
    callbacks = callbacks(self())
    TuiState.put_workspace(state, %{kind: "plugins", records: []})

    assert {:submit, "ooo auto improve startup"} =
             TuiSubmit.handle("ooo auto improve startup", %{}, output, state, 80, 24, callbacks)

    assert %{
             kind: "workflow",
             title: "Auto Run",
             status: "approval plan starting",
             detail: %{
               title: "Auto run",
               fields: %{
                 current: "interview -> seed -> execute -> verify",
                 progress: ["starting now", "approval checkpoint before file changes"]
               }
             }
           } = TuiState.workspace(state)
  end

  test "handle cancel targets an active interview before slash dispatch", %{
    output: output,
    state: state
  } do
    callbacks = callbacks(self())
    parent = self()

    result = %{
      pane_snapshot: fn -> %{interview: %{question: "Stop?"}, paused: true} end,
      interview_answer: fn answer ->
        send(parent, {:answer, answer})
        {:ok, answer}
      end
    }

    TuiState.put_workspace(state, %{kind: "agents", records: []})

    assert :continue = TuiSubmit.handle("/cancel", result, output, state, 80, 24, callbacks)
    assert_received {:answer, "cancel"}
    assert TuiState.mode(state) == :normal

    assert %{kind: "interview", title: "Interview Stopped", status: "cancelled"} =
             workspace =
             TuiState.workspace(state)

    assert get_in(workspace, [:detail, :title]) == "Interview stopped"

    {_input, captured} = StringIO.contents(output)
    assert captured == ""
    refute captured =~ "you> /cancel"
    refute captured =~ "existing output"
  end

  test "handle slash answer closes palette state before redrawing", %{
    output: output,
    state: state
  } do
    callbacks = callbacks(self())
    parent = self()

    TuiState.put_mode(state, :palette)
    TuiState.put_pidx(state, 3)

    result = %{
      pane_snapshot: fn -> %{interview: %{question: "Continue?"}, paused: true} end,
      interview_answer: fn answer ->
        send(parent, {:answer, answer})
        {:ok, answer}
      end
    }

    assert :continue =
             TuiSubmit.handle(
               "/answer proceed with setup",
               result,
               output,
               state,
               80,
               24,
               callbacks
             )

    assert_received {:answer, "proceed with setup"}
    assert TuiState.mode(state) == :normal
    assert TuiState.pidx(state) == 0
  end

  test "handle clears captured output and redraws", %{output: output, state: state} do
    callbacks = callbacks(self())

    assert :continue = TuiSubmit.handle("/clear", %{}, output, state, 80, 24, callbacks)
    assert StringIO.contents(output) == {"", ""}
    assert_receive {:redraw, "", 80, 24}
  end

  test "handle exits on quit commands", %{output: output, state: state} do
    callbacks = callbacks(self())

    assert :exit = TuiSubmit.handle("/exit", %{}, output, state, 80, 24, callbacks)
    assert :exit = TuiSubmit.handle("/quit", %{}, output, state, 80, 24, callbacks)
  end

  defp callbacks(parent) do
    [
      active_model: fn _state -> nil end,
      redraw: fn _result, _output, _state, prompt, cols, rows ->
        send(parent, {:redraw, prompt, cols, rows})
        :ok
      end
    ]
  end

  defp safe_close(pid, close) when is_pid(pid) and is_function(close, 1) do
    if Process.alive?(pid), do: close.(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
