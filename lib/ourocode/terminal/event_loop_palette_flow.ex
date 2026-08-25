defmodule Ourocode.Terminal.EventLoopPaletteFlow do
  @moduledoc """
  Command palette state transitions for the terminal event loop.
  """

  alias Ourocode.Terminal.CommandInput
  alias Ourocode.Terminal.EventLoopCommandPalette
  alias Ourocode.Terminal.EventLoopJournal
  alias Ourocode.Terminal.EventLoopState

  @spec open(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def open(line, state, registry) when is_binary(line) and is_map(state) and is_map(registry) do
    palette_event = EventLoopCommandPalette.open_event(line, registry)

    case EventLoopJournal.persist(state.journal_path, palette_event) do
      {:ok, palette_event} ->
        IO.puts(state.output, EventLoopCommandPalette.render_text(palette_event.registry))
        state.on_command_palette.(palette_event, state.startup_result)

        {:ok,
         %{
           state
           | iterations: state.iterations + 1,
             active_command_palette: %{registry: registry, opened_event: palette_event},
             command_palette_events:
               EventLoopState.remember(state.command_palette_events, palette_event)
         }}

      {:error, reason} ->
        {:error, {:command_palette_event_journal_append_failed, reason}}
    end
  end

  @spec select(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def select(
        line,
        %{active_command_palette: %{registry: registry, opened_event: opened_event}} = state
      )
      when is_binary(line) do
    case EventLoopCommandPalette.select_event(line, registry, opened_event, state) do
      {:ok, {selected_entry, selection_event}} ->
        persist_selection(selected_entry, selection_event, state)

      {:error, selection_error} ->
        record_selection_error(selection_error, state)
    end
  end

  defp persist_selection(selected_entry, selection_event, state) do
    case EventLoopJournal.persist(state.journal_path, selection_event) do
      {:ok, selection_event} ->
        IO.puts(state.output, "selected #{selected_entry.slash}: #{selected_entry.summary}")
        state.on_command_palette_selection.(selection_event, state.startup_result)

        {:ok,
         %{
           state
           | iterations: state.iterations + 1,
             active_command_palette: nil,
             command_palette_events:
               EventLoopState.remember(state.command_palette_events, selection_event)
         }}

      {:error, reason} ->
        {:error, {:command_palette_selection_event_journal_append_failed, reason}}
    end
  end

  defp record_selection_error(selection_error, state) do
    case EventLoopJournal.append(state.journal_path, selection_error) do
      :ok ->
        IO.puts(
          state.output,
          "palette selection failed: #{CommandInput.format_error(selection_error.reason)}"
        )

        {:ok,
         %{
           state
           | iterations: state.iterations + 1,
             recoverable_errors:
               EventLoopState.remember(state.recoverable_errors, selection_error)
         }}

      {:error, reason} ->
        {:error, {:recoverable_error_journal_append_failed, reason}}
    end
  end
end
