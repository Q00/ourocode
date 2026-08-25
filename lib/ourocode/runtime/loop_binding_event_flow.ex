defmodule Ourocode.Runtime.LoopBindingEventFlow do
  @moduledoc """
  Runtime event inbox and live pane folding for loop bindings.
  """

  alias Ourocode.ACP.Projection, as: AcpProjection
  alias Ourocode.Dashboard.PaneOrchestrator
  alias Ourocode.Runtime.{InterviewState, WorkflowHarness, WonderDetection}

  @spec enqueue(pid(), map()) :: :ok
  def enqueue(agent, event) when is_pid(agent) and is_map(event) do
    Agent.update(agent, fn state ->
      inbox =
        bounded_enqueue(
          Map.get(state, :inbox, :queue.new()),
          event,
          Map.get(state, :inbox_limit, 2_000)
        )

      state
      |> Map.put(:inbox, inbox)
      |> fold_event(event)
    end)
  end

  defp bounded_enqueue(queue, event, limit) do
    queue = if :queue.len(queue) >= limit, do: drop_oldest(queue), else: queue
    :queue.in(event, queue)
  end

  defp drop_oldest(queue) do
    case :queue.out(queue) do
      {{:value, _event}, rest} -> rest
      {:empty, queue} -> queue
    end
  end

  @spec poll_fun(pid()) :: (map() -> {:ok, map()} | {:none, map()})
  def poll_fun(agent) when is_pid(agent) do
    fn _state ->
      Agent.get_and_update(agent, fn state ->
        case :queue.out(state.inbox) do
          {{:value, event}, rest} -> {{:ok, event}, %{state | inbox: rest}}
          {:empty, _inbox} -> {:none, state}
        end
      end)
    end
  end

  @spec runtime_event_fun(pid()) :: (map(), map() -> :ok)
  def runtime_event_fun(_agent) do
    fn _runtime_event, _startup_result -> :ok end
  end

  @spec fold_event(map(), map()) :: map()
  def fold_event(state, event) do
    orchestrated =
      state
      |> PaneOrchestrator.apply_event(event)

    state
    |> Map.update(:acp, AcpProjection.new(), &AcpProjection.apply_runtime_event(&1, event))
    |> WorkflowHarness.apply_event(event)
    |> Map.put(:parent, PaneOrchestrator.parent_state(orchestrated))
    |> Map.put(:child, PaneOrchestrator.child_state(orchestrated))
    |> Map.put(:mcp_topology, PaneOrchestrator.topology_state(orchestrated))
    |> WonderDetection.apply(event)
    |> InterviewState.detect(event)
  end
end
