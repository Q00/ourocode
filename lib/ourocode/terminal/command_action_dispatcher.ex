defmodule Ourocode.Terminal.CommandActionDispatcher do
  @moduledoc """
  Routes builtin command actions to their terminal command family modules.
  """

  alias Ourocode.Terminal.CommandChildControlCommands
  alias Ourocode.Terminal.CommandDiscoveryCommands
  alias Ourocode.Terminal.CommandModelCommands
  alias Ourocode.Terminal.CommandPreflightCommands
  alias Ourocode.Terminal.CommandStatusCommands
  alias Ourocode.Terminal.CommandThemeCommands
  alias Ourocode.Terminal.CommandWorkflowApprovalCommands
  alias Ourocode.Terminal.ResumeSessions

  @spec dispatch(term(), map(), map(), map(), map()) :: {:ok, term()} | {:error, term()}
  def dispatch(action, command_event, entry, state, registry) do
    cond do
      CommandChildControlCommands.handles?(action) ->
        CommandChildControlCommands.dispatch(action, command_event, state)

      ResumeSessions.handles?(action) ->
        ResumeSessions.dispatch(action, command_event, state)

      CommandDiscoveryCommands.handles?(action) ->
        CommandDiscoveryCommands.render(action, state, registry)

      CommandPreflightCommands.handles?(action) ->
        CommandPreflightCommands.render(action, command_event, state, registry)

      CommandModelCommands.handles?(action) ->
        CommandModelCommands.render(action, command_event, state)

      CommandStatusCommands.handles?(action) ->
        CommandStatusCommands.render(action, state)

      CommandThemeCommands.handles?(action) ->
        CommandThemeCommands.dispatch(action, command_event, state)

      CommandWorkflowApprovalCommands.handles?(action) ->
        CommandWorkflowApprovalCommands.dispatch(action, command_event, state)

      true ->
        {:ok, %{command_entry: entry}}
    end
  end
end
