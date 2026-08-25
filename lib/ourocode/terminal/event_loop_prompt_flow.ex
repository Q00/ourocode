defmodule Ourocode.Terminal.EventLoopPromptFlow do
  @moduledoc """
  Prompt lifecycle state transforms used by the terminal event loop.
  """

  alias Ourocode.Terminal.{EventLoopPromptState, EventLoopState, SteeringPane}

  @spec accept_input_event(map(), map()) :: map()
  def accept_input_event(state, input_event) when is_map(state) and is_map(input_event) do
    %{
      state
      | pane_model: SteeringPane.append_to_target_child_pane(state.pane_model, input_event),
        accepted_input_buffer: EventLoopState.remember(state.accepted_input_buffer, input_event)
    }
  end

  @spec transition_state(map(), :dispatching_input | :awaiting_prompt, map()) :: map()
  def transition_state(state, prompt_state, input_event)
      when is_map(state) and is_map(input_event) do
    state_event = EventLoopPromptState.event(prompt_state, input_event)
    state.on_prompt_state_change.(state_event, state.startup_result)

    %{
      state
      | prompt_state: prompt_state,
        prompt_state_events: EventLoopState.remember(state.prompt_state_events, state_event)
    }
  end
end
