defmodule Ourocode.Terminal.EventLoopCommandDispatch do
  @moduledoc """
  Slash-command dispatch boundary for the terminal event loop.
  """

  alias Ourocode.Terminal.CommandHandler
  alias Ourocode.Terminal.CommandInput
  alias Ourocode.Terminal.EventLoopFocus
  alias Ourocode.Terminal.EventLoopJournal
  alias Ourocode.Terminal.EventLoopState

  @spec submit(map(), map()) :: {:ok, map()} | {:error, term()}
  def submit(command_event, state) when is_map(command_event) and is_map(state) do
    case EventLoopJournal.persist(state.journal_path, command_event) do
      {:ok, command_event} ->
        with {:ok, state} <- EventLoopFocus.maybe_switch_from_command(command_event, state) do
          dispatch_persisted(command_event, state)
        end

      {:error, reason} ->
        {:error, {:command_event_journal_append_failed, reason}}
    end
  end

  @spec dispatch_persisted(map(), map()) :: {:ok, map()} | {:error, term()}
  def dispatch_persisted(command_event, state) when is_map(command_event) and is_map(state) do
    case dispatch(command_event, state) do
      :ok ->
        {:ok, record_command(state, command_event)}

      {:ok, new_state} when is_map(new_state) ->
        {:ok, record_command(new_state, command_event)}

      {:error, reason} ->
        record_command_error(state, command_event, reason)
    end
  end

  @spec dispatch(map(), map()) :: :ok | {:ok, map()} | {:error, term()}
  def dispatch(command_event, state) when is_map(command_event) and is_map(state) do
    try do
      case invoke_handler(command_event, state) do
        :ok -> :ok
        {:ok, %{state: new_state}} when is_map(new_state) -> {:ok, new_state}
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, {:invalid_command_handler_result, other}}
      end
    rescue
      exception ->
        {:error, {:command_handler_exception, exception.__struct__, Exception.message(exception)}}
    catch
      kind, reason ->
        {:error, {:command_handler_caught, kind, reason}}
    end
  end

  defp invoke_handler(command_event, %{on_command: :default_command_handler} = state) do
    CommandHandler.handle(command_event, state)
  end

  defp invoke_handler(command_event, %{on_command: on_command} = state)
       when is_function(on_command, 4) do
    on_command.(command_event, command_event.args, state.startup_result, state)
  end

  defp invoke_handler(command_event, %{on_command: on_command} = state)
       when is_function(on_command, 3) do
    on_command.(command_event, command_event.args, state.startup_result)
  end

  defp invoke_handler(_command_event, %{on_command: on_command}) do
    {:error, {:invalid_command_handler, on_command}}
  end

  defp record_command(state, command_event) do
    %{
      state
      | iterations: state.iterations + 1,
        command_events: EventLoopState.remember(state.command_events, command_event)
    }
  end

  defp record_command_error(state, command_event, reason) do
    command_error = CommandInput.command_error_event(command_event, reason)
    EventLoopJournal.append(state.journal_path, command_error)
    state.on_command_error.(command_error, command_event, state.startup_result)
    report_error(state.output, command_event, reason)

    {:ok,
     %{
       state
       | iterations: state.iterations + 1,
         command_events: EventLoopState.remember(state.command_events, command_event),
         command_errors: EventLoopState.remember(state.command_errors, command_error)
     }}
  end

  defp report_error(output, command_event, reason) do
    IO.puts(
      output,
      "command #{command_event.command} failed: #{CommandInput.format_error(reason)}"
    )
  end
end
