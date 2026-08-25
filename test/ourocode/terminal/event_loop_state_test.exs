defmodule Ourocode.Terminal.EventLoopStateTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.EventLoopState

  test "builds initial event loop state from options and defaults" do
    parent = self()

    state =
      EventLoopState.build(
        %{status: :healthy},
        %{
          prompt: "test> ",
          read_line: fn _prompt -> :eof end,
          on_task: fn task_request, startup_result ->
            send(parent, {:task, task_request.task_input, startup_result.status})
            :ok
          end,
          exit_signals: ["done"]
        },
        "ourocode> "
      )

    assert state.prompt == "test> "
    assert state.read_line.("test> ") == :eof
    assert MapSet.member?(state.exit_signals, "done")
    assert state.prompt_state == :awaiting_prompt
    assert state.iterations == 0
    assert state.recoverable_errors == []

    assert {:ok, task_request} = Ourocode.TaskRequest.parse("hello")
    assert :ok = state.on_prompt_input.(task_request, %{}, %{status: :healthy})
    assert_receive {:task, "hello", :healthy}
  end

  test "default callbacks are no-ops and runtime poller returns none" do
    state = EventLoopState.build(%{status: :healthy}, [], "ourocode> ")

    assert :none = state.poll_runtime_event.(%{})
    assert :ok = state.on_input_event.(%{}, %{})
    assert :ok = state.on_command_palette.(%{}, %{})
    assert :ok = state.on_command_palette_selection.(%{}, %{})
    assert :ok = state.on_command_error.(%{}, %{}, %{})
    assert :ok = state.on_prompt_state_change.(%{}, %{})
    assert :ok = state.on_runtime_event.(%{}, %{})
    assert :ok = state.on_focus_event.(%{}, %{})
    assert :ok = state.on_release_resources.(%{}, %{})
  end

  test "remember retains only the newest bounded history" do
    history = Enum.reduce(1..750, [], fn event, acc -> EventLoopState.remember(acc, event) end)

    assert length(history) == EventLoopState.history_limit()
    assert hd(history) == 750
    assert List.last(history) == 251
  end
end
