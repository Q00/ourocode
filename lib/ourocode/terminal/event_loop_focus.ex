defmodule Ourocode.Terminal.EventLoopFocus do
  @moduledoc """
  Focus transitions owned by the terminal event loop.
  """

  alias Ourocode.Runtime.FocusState
  alias Ourocode.Terminal.EventLoopJournal
  alias Ourocode.Terminal.FocusNavigation
  alias Ourocode.Terminal.EventLoopState

  @spec handle_keyboard(map(), map()) ::
          {:ok, map()} | {:error, {:focus_event_journal_append_failed, term()}}
  def handle_keyboard(key_input, state) do
    case FocusNavigation.resolve_keyboard_focus_target(key_input, state.keyboard_focus_bindings) do
      {:ok, target_pane_id} ->
        maybe_switch_from_keyboard(key_input, target_pane_id, state)

      :ignore ->
        {:ok, %{state | iterations: state.iterations + 1}}
    end
  end

  @spec maybe_switch_from_command(map(), map()) ::
          {:ok, map()} | {:error, {:focus_event_journal_append_failed, term()}}
  def maybe_switch_from_command(command_event, state) do
    case FocusNavigation.command_focus_target(command_event) do
      {:ok, target_pane_id} ->
        if FocusNavigation.same_pane?(
             state.focus_state.focused_pane,
             target_pane_id,
             state.pane_model
           ) do
          {:ok, state}
        else
          switch_from_command(command_event, target_pane_id, state)
        end

      :ignore ->
        {:ok, state}
    end
  end

  defp maybe_switch_from_keyboard(key_input, target_pane_id, state) do
    if FocusNavigation.same_pane?(
         state.focus_state.focused_pane,
         target_pane_id,
         state.pane_model
       ) do
      {:ok, %{state | iterations: state.iterations + 1}}
    else
      case FocusState.focus_pane(state.focus_state, target_pane_id, state.pane_model,
             occurred_at_ms: System.system_time(:millisecond)
           ) do
        {:ok, focus_state, focus_event} ->
          record_keyboard_event(state, focus_state, focus_event, key_input)

        {:error, reason, _unchanged_state} ->
          keyboard_error = FocusNavigation.keyboard_focus_error_event(key_input, reason)
          EventLoopJournal.append(state.journal_path, keyboard_error)

          {:ok,
           %{
             state
             | iterations: state.iterations + 1,
               recoverable_errors:
                 EventLoopState.remember(state.recoverable_errors, keyboard_error)
           }}
      end
    end
  end

  defp record_keyboard_event(state, focus_state, nil, _key_input) do
    {:ok, %{state | iterations: state.iterations + 1, focus_state: focus_state}}
  end

  defp record_keyboard_event(state, focus_state, focus_event, key_input) do
    focus_event = FocusNavigation.keyboard_focus_event(focus_event, key_input)

    case EventLoopJournal.append(state.journal_path, focus_event) do
      :ok ->
        state.on_focus_event.(focus_event, state.startup_result)

        {:ok,
         %{
           state
           | iterations: state.iterations + 1,
             focus_state: focus_state,
             focus_events: EventLoopState.remember(state.focus_events, focus_event)
         }}

      {:error, reason} ->
        {:error, {:focus_event_journal_append_failed, reason}}
    end
  end

  defp switch_from_command(command_event, target_pane_id, state) do
    case FocusState.focus_pane(state.focus_state, target_pane_id, state.pane_model,
           occurred_at_ms: System.system_time(:millisecond)
         ) do
      {:ok, focus_state, focus_event} ->
        record_command_event(state, focus_state, focus_event, command_event)

      {:error, _reason, _unchanged_state} ->
        {:ok, state}
    end
  end

  defp record_command_event(state, focus_state, nil, _command_event) do
    {:ok, %{state | focus_state: focus_state}}
  end

  defp record_command_event(state, focus_state, focus_event, command_event) do
    focus_event = FocusNavigation.command_focus_event(focus_event, command_event)

    case EventLoopJournal.append(state.journal_path, focus_event) do
      :ok ->
        state.on_focus_event.(focus_event, state.startup_result)

        {:ok,
         %{
           state
           | focus_state: focus_state,
             focus_events: EventLoopState.remember(state.focus_events, focus_event)
         }}

      {:error, reason} ->
        {:error, {:focus_event_journal_append_failed, reason}}
    end
  end
end
