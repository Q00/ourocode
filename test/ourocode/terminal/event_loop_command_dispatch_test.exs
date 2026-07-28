defmodule Ourocode.Terminal.EventLoopCommandDispatchTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.CommandInput
  alias Ourocode.Terminal.EventLoopCommandDispatch
  alias Ourocode.Terminal.EventLoopState
  alias Ourocode.Terminal.TuiState

  test "submit persists a command event and records successful dispatch" do
    command_event = CommandInput.command_event("/status")
    state = state(on_command: fn _event, _args, _startup -> :ok end)

    assert {:ok, state} = EventLoopCommandDispatch.submit(command_event, state)

    assert state.iterations == 1
    assert [%{command: "/status"}] = state.command_events
    assert state.command_errors == []
  end

  test "submit records command handler failures as recoverable command errors" do
    command_event = CommandInput.command_event("/missing")
    output = string_io()

    state =
      state(
        output: output,
        on_command: fn _event, _args, _startup -> {:error, {:unknown_command, "/missing", []}} end
      )

    assert {:ok, state} = EventLoopCommandDispatch.submit(command_event, state)

    assert state.iterations == 1
    assert [%{command: "/missing"}] = state.command_events
    assert [%{type: :slash_command_failed, command: "/missing"}] = state.command_errors

    assert {_input, output_text} = StringIO.contents(output)
    assert output_text =~ "command /missing failed: unknown command /missing"
  end

  test "submit accepts command handlers that return an updated loop state" do
    command_event = CommandInput.command_event("/approve")

    state =
      state(
        on_command: fn _event, _args, _startup, loop_state ->
          {:ok, %{state: Map.put(loop_state, :approval_seen?, true)}}
        end
      )

    assert {:ok, state} = EventLoopCommandDispatch.submit(command_event, state)

    assert state.approval_seen? == true
    assert state.iterations == 1
    assert [%{command: "/approve"}] = state.command_events
  end

  test "default command handler sees live TUI model state for model commands" do
    tui_state = TuiState.start_link()
    TuiState.put_model_id(tui_state, :codex)
    output = string_io()

    on_exit(fn -> safe_stop(tui_state) end)

    state =
      state(
        output: output,
        on_command: :default_command_handler,
        tui_state: tui_state
      )

    assert {:ok, state} =
             EventLoopCommandDispatch.submit(CommandInput.command_event("/model"), state)

    assert {:ok, state} =
             EventLoopCommandDispatch.submit(
               CommandInput.command_event("/model gpt-5.5"),
               state
             )

    assert state.iterations == 2
    assert TuiState.provider_model_slug(tui_state, :codex) == "gpt-5.5"

    {_input, text} = StringIO.contents(output)
    assert text =~ "Codex models"
    assert text =~ "gpt-5.5"
    assert text =~ "gpt-5.3-codex"
    assert text =~ "model: gpt-5.5 selected for codex"
    refute text =~ "no models for ; 0 choices"
    refute text =~ "no active TUI state is available"
  end

  test "dispatch normalizes raised command handler exceptions" do
    command_event = CommandInput.command_event("/explode")

    state =
      state(
        on_command: fn _event, _args, _startup ->
          raise ArgumentError, "bad command"
        end
      )

    assert {:error, {:command_handler_exception, ArgumentError, "bad command"}} =
             EventLoopCommandDispatch.dispatch(command_event, state)
  end

  defp state(options) do
    options =
      Keyword.merge(
        [
          output: string_io(),
          on_command_error: fn _error, _event, _startup -> :ok end
        ],
        options
      )

    EventLoopState.build(%{status: :healthy}, options, "ourocode> ")
  end

  defp string_io do
    {:ok, output} = StringIO.open("")
    output
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: Agent.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
