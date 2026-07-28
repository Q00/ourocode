defmodule Ourocode.Terminal.EventLoopState do
  @moduledoc """
  Builds the initial state map for the terminal event loop.
  """

  alias Ourocode.Runtime.FocusState
  alias Ourocode.Terminal.{EventLoopExit, FocusNavigation}

  @spec build(map(), keyword() | map(), String.t()) :: map()
  def build(startup_result, options, default_prompt) when is_map(startup_result) do
    options = Map.new(options)
    prompt = Map.get(options, :prompt, default_prompt)
    input = Map.get(options, :input, :stdio)
    output = Map.get(options, :output, :stdio)
    read_line = Map.get(options, :read_line, &IO.gets(input, &1))
    on_task = Map.get(options, :on_task, &default_task_handler/2)

    %{
      startup_result: startup_result,
      output: output,
      read_line: read_line,
      on_prompt_input:
        Map.get(options, :on_prompt_input, prompt_processor_from_task_handler(on_task)),
      on_input_event: Map.get(options, :on_input_event, &default_input_event_handler/2),
      on_command: Map.get(options, :on_command, :default_command_handler),
      on_command_palette:
        Map.get(options, :on_command_palette, &default_command_palette_handler/2),
      on_command_palette_selection:
        Map.get(
          options,
          :on_command_palette_selection,
          &default_command_palette_selection_handler/2
        ),
      command_dispatch_options: Map.get(options, :command_dispatch_options, %{}),
      on_command_error: Map.get(options, :on_command_error, &default_command_error_handler/3),
      on_focus_event: Map.get(options, :on_focus_event, &default_focus_event_handler/2),
      poll_runtime_event: Map.get(options, :poll_runtime_event, &default_runtime_event_poller/1),
      on_runtime_event: Map.get(options, :on_runtime_event, &default_runtime_event_handler/2),
      on_prompt_state_change:
        Map.get(options, :on_prompt_state_change, &default_prompt_state_change_handler/2),
      on_release_resources: Map.get(options, :on_release_resources, &default_release_resources/2),
      journal_path: Map.get(options, :journal_path),
      exit_signals: EventLoopExit.exit_signals(options),
      prompt: prompt,
      prompt_state: :awaiting_prompt,
      prompt_state_events: [],
      iterations: 0,
      submitted_tasks: [],
      input_events: [],
      accepted_input_buffer: [],
      runtime_events: [],
      plugin_status_updates: [],
      command_events: [],
      command_palette_events: [],
      active_command_palette: nil,
      command_errors: [],
      focus_events: [],
      focus_state: Map.get(options, :focus_state, FocusState.new()),
      pane_model: Map.get(options, :pane_model, FocusNavigation.default_pane_model()),
      tui_state: Map.get(options, :tui_state),
      keyboard_focus_bindings: FocusNavigation.keyboard_focus_bindings(options),
      recoverable_errors: []
    }
  end

  def default_task_handler(_task_request, _startup_result), do: :ok
  def default_input_event_handler(_input_event, _startup_result), do: :ok
  def default_command_palette_handler(_palette_event, _startup_result), do: :ok
  def default_command_palette_selection_handler(_selection_event, _startup_result), do: :ok
  def default_runtime_event_poller(_state), do: :none
  def default_runtime_event_handler(_runtime_event, _startup_result), do: :ok
  def default_focus_event_handler(_focus_event, _startup_result), do: :ok

  def default_release_resources(%{runtime: runtime}, _state),
    do: Ourocode.Runtime.Application.stop(runtime)

  def default_release_resources(_startup_result, _state), do: :ok

  def default_command_error_handler(_command_error, _command_event, _startup_result), do: :ok
  def default_prompt_state_change_handler(_state_event, _startup_result), do: :ok

  defp prompt_processor_from_task_handler(on_task) when is_function(on_task, 2) do
    fn task_request, _input_event, startup_result ->
      on_task.(task_request, startup_result)
    end
  end
end
