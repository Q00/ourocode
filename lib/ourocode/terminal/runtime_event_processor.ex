defmodule Ourocode.Terminal.RuntimeEventProcessor do
  @moduledoc false

  alias Ourocode.Journal
  alias Ourocode.Terminal.{EventLoopState, PluginStatus, RuntimeEventFlow, WorkflowLaneLifecycle}

  @spec drain(map()) :: {:ok, map()} | {:error, term()}
  def drain(state) when is_map(state) do
    case poll_runtime_event(state) do
      :none ->
        {:ok, state}

      {:ok, event} ->
        case submit(event, state) do
          {:ok, state} -> drain(state)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        recoverable_error =
          RuntimeEventFlow.recoverable_error_event(
            :runtime_event_poll_failed,
            reason,
            :terminal_runtime_event_poll
          )

        record_recoverable_error(recoverable_error, state)
    end
  end

  @spec submit(map(), map()) :: {:ok, map()} | {:error, term()}
  def submit(event, state) when is_map(event) and is_map(state) do
    runtime_event = RuntimeEventFlow.normalize_event(event)

    with :ok <- maybe_append_input_event(state.journal_path, runtime_event),
         {:ok, state} <- PluginStatus.apply_reload_event(runtime_event, state),
         {:ok, state} <- apply_child_session_registration(runtime_event, state),
         {:ok, state} <- apply_workflow_lifecycle_event(runtime_event, state),
         {:ok, state} <- dispatch_runtime_event(runtime_event, state) do
      state =
        %{state | runtime_events: EventLoopState.remember(state.runtime_events, runtime_event)}
        |> maybe_record_recoverable_runtime_event(runtime_event)

      {:ok, state}
    else
      {:error, {:recoverable_runtime_event_handler_failed, reason}} ->
        recoverable_error =
          RuntimeEventFlow.recoverable_error_event(
            :runtime_event_handler_failed,
            reason,
            Map.get(runtime_event, :type)
          )

        with {:ok, state} <- record_recoverable_error(recoverable_error, state) do
          {:ok,
           %{state | runtime_events: EventLoopState.remember(state.runtime_events, runtime_event)}}
        end

      {:error, reason} ->
        {:error, {:runtime_event_append_failed, reason}}
    end
  end

  defp poll_runtime_event(%{poll_runtime_event: poll_runtime_event} = state) do
    RuntimeEventFlow.poll(poll_runtime_event, state)
  end

  defp dispatch_runtime_event(runtime_event, state) do
    case state.on_runtime_event.(runtime_event, state.startup_result) do
      :ok -> {:ok, state}
      {:ok, _result} -> {:ok, state}
      {:error, reason} -> {:error, {:recoverable_runtime_event_handler_failed, reason}}
      other -> {:error, {:recoverable_runtime_event_handler_failed, {:invalid_result, other}}}
    end
  rescue
    exception ->
      {:error,
       {:recoverable_runtime_event_handler_failed,
        {:exception, exception.__struct__, Exception.message(exception)}}}
  catch
    kind, reason ->
      {:error, {:recoverable_runtime_event_handler_failed, {:caught, kind, reason}}}
  end

  defp maybe_record_recoverable_runtime_event(state, runtime_event) do
    if RuntimeEventFlow.recoverable_event?(runtime_event) do
      recoverable_error =
        RuntimeEventFlow.recoverable_error_event(
          Map.get(runtime_event, :type, :recoverable_runtime_event),
          Map.get(runtime_event, :reason) || Map.get(runtime_event, :error) || runtime_event,
          Map.get(runtime_event, :source, :runtime)
        )

      %{
        state
        | recoverable_errors: EventLoopState.remember(state.recoverable_errors, recoverable_error)
      }
    else
      state
    end
  end

  defp apply_workflow_lifecycle_event(%{type: type} = runtime_event, state)
       when type in [
              :stream_started,
              :stream_event,
              :paused,
              :resumed,
              :cancelled,
              :failed,
              :completed
            ] do
    case workflow_pane_id(runtime_event) do
      pane_id when is_binary(pane_id) ->
        {:ok,
         Map.update(state, :pane_model, %{}, fn pane_model ->
           WorkflowLaneLifecycle.apply_event(pane_model, pane_id, runtime_event)
         end)}

      nil ->
        {:ok, state}
    end
  end

  defp apply_workflow_lifecycle_event(_runtime_event, state), do: {:ok, state}

  defp apply_child_session_registration(%{type: :child_session_registered} = event, state) do
    pane_id = Map.get(event, :pane_id)
    child_id = Map.get(event, :child_id) || Map.get(event, :session_id)

    if is_binary(pane_id) and is_binary(child_id) do
      pane = %{
        id: pane_id,
        kind: :child_session,
        child_id: child_id,
        parent_call_id: Map.get(event, :parent_call_id),
        runtime_source: Map.get(event, :runtime_source, "ouroboros"),
        transport: Map.get(event, :transport, :streamable_http),
        external_ids: Map.get(event, :external_ids, %{}),
        status: Map.get(event, :status, "running"),
        title: Map.get(event, :title, "Ouroboros workflow"),
        task: Map.get(event, :task, "Ouroboros workflow"),
        last_line: Map.get(event, :line, "background session attached"),
        pane_state: Map.get(event, :pane_state, %{}),
        visible?: true
      }

      pane_model =
        state
        |> Map.get(:pane_model, %{panes: %{}, open: []})
        |> register_child_pane(pane_id, pane)

      {:ok, %{state | pane_model: pane_model}}
    else
      {:ok, state}
    end
  end

  defp apply_child_session_registration(_runtime_event, state), do: {:ok, state}

  defp register_child_pane(pane_model, pane_id, pane) do
    panes = Map.get(pane_model, :panes, %{})
    open = Map.get(pane_model, :open, [])

    pane_model
    |> Map.put(:panes, Map.put(panes, pane_id, Map.merge(Map.get(panes, pane_id, %{}), pane)))
    |> Map.put(:open, Enum.uniq(open ++ [pane_id]))
  end

  defp workflow_pane_id(runtime_event) do
    cond do
      is_binary(Map.get(runtime_event, :pane_id)) ->
        Map.get(runtime_event, :pane_id)

      is_binary(Map.get(runtime_event, "pane_id")) ->
        Map.get(runtime_event, "pane_id")

      is_binary(Map.get(runtime_event, :workflow_id)) ->
        "workflow:" <> Map.get(runtime_event, :workflow_id)

      is_binary(Map.get(runtime_event, "workflow_id")) ->
        "workflow:" <> Map.get(runtime_event, "workflow_id")

      true ->
        nil
    end
  end

  defp record_recoverable_error(recoverable_error, state) do
    case maybe_append_input_event(state.journal_path, recoverable_error) do
      :ok ->
        {:ok,
         %{
           state
           | recoverable_errors:
               EventLoopState.remember(state.recoverable_errors, recoverable_error)
         }}

      {:error, reason} ->
        {:error, {:recoverable_error_journal_append_failed, reason}}
    end
  end

  defp maybe_append_input_event(nil, _input_event), do: :ok

  defp maybe_append_input_event(journal_path, input_event) when is_binary(journal_path) do
    Journal.append(journal_path, input_event)
  end
end
