defmodule Ourocode.Runtime.Dispatcher.RouteResolution do
  @moduledoc false

  alias Ourocode.TaskRequest

  @supported_routes [:runtime, :ouroboros_workflow, :mcp_flow, :user_level_plugin]
  @supported_runtime_sources [:auto, :codex, :opencode, :claude_code, :ouroboros, :mcp]
  @supported_transports [:auto, :stdio, :streamable_http, :sse]
  @supported_adapter_routes [:interview, :seed, :run, :evolve, :ralph, :workflow]

  @spec validate_decision(map()) :: :ok | {:error, term()}
  def validate_decision(decision) do
    with {:ok, execution_route} <- required_atom(decision, :execution_route),
         {:ok, kind} <- required_atom(decision, :kind),
         {:ok, runtime_source} <- required_atom(decision, :runtime_source),
         {:ok, transport} <- required_atom(decision, :transport),
         :ok <- ensure_supported(:execution_route, execution_route, @supported_routes),
         :ok <- ensure_supported(:kind, kind, @supported_routes),
         :ok <- ensure_matching_route(kind, execution_route),
         :ok <- ensure_supported(:runtime_source, runtime_source, @supported_runtime_sources),
         :ok <- ensure_supported(:transport, transport, @supported_transports),
         :ok <- validate_adapter_route(decision) do
      :ok
    end
  end

  @spec resolve_adapter(TaskRequest.t(), map(), map()) :: {:ok, module()} | {:error, map()}
  def resolve_adapter(%TaskRequest{} = task_request, routing_decision, adapters)
      when is_map(routing_decision) and is_map(adapters) do
    adapter_keys = adapter_keys(routing_decision)

    case find_adapter(adapters, adapter_keys) do
      nil -> {:error, unsupported_task_error(task_request, routing_decision, adapter_keys)}
      adapter -> {:ok, adapter}
    end
  end

  @spec ensure_adapter(term()) :: :ok | {:error, term()}
  def ensure_adapter(adapter) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :execute, 2) do
      :ok
    else
      {:error, {:invalid_adapter, adapter}}
    end
  end

  def ensure_adapter(adapter), do: {:error, {:invalid_adapter, adapter}}

  @spec unsupported_task_error(TaskRequest.t(), TaskRequest.routing_decision(), list()) :: map()
  def unsupported_task_error(%TaskRequest{} = task_request, routing_decision, adapter_keys)
      when is_map(routing_decision) and is_list(adapter_keys) do
    %{
      code: :unsupported_task,
      message: unsupported_task_message(routing_decision),
      task_input: task_request.task_input,
      routing_decision: routing_decision,
      attempted_adapter_keys: adapter_keys
    }
  end

  @spec adapter_keys(map()) :: [atom() | {atom(), atom()}]
  def adapter_keys(%{
        execution_route: :ouroboros_workflow,
        runtime_source: :ouroboros,
        adapter_route: adapter_route
      }) do
    [
      {:ouroboros_workflow, adapter_route},
      {:ouroboros, adapter_route},
      :"ouroboros_#{adapter_route}",
      :ouroboros,
      :ouroboros_workflow
    ]
  end

  def adapter_keys(%{execution_route: :mcp_flow, runtime_source: :mcp, transport: :auto}) do
    [:mcp, :mcp_flow]
  end

  def adapter_keys(%{execution_route: :mcp_flow, runtime_source: :mcp, transport: transport}) do
    [
      {:mcp_flow, transport},
      {:mcp, transport},
      :"mcp_#{transport}",
      :mcp,
      :mcp_flow
    ]
  end

  def adapter_keys(%{execution_route: :user_level_plugin, plugin_id: plugin_id})
      when is_binary(plugin_id) and plugin_id != "" do
    [{:user_level_plugin, plugin_id}, :user_level_plugin]
  end

  def adapter_keys(%{execution_route: :user_level_plugin}) do
    [:user_level_plugin]
  end

  def adapter_keys(%{execution_route: route, runtime_source: runtime_source}) do
    adapter_keys(route, runtime_source)
  end

  defp required_atom(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_atom(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_routing_decision, key, value}}
      :error -> {:error, {:missing_routing_decision_field, key}}
    end
  end

  defp ensure_supported(field, value, supported) do
    if Enum.member?(supported, value) do
      :ok
    else
      {:error, {:unsupported_routing_decision, field, value}}
    end
  end

  defp ensure_matching_route(route, route), do: :ok

  defp ensure_matching_route(kind, execution_route) do
    {:error, {:route_mismatch, kind, execution_route}}
  end

  defp validate_adapter_route(%{
         execution_route: :ouroboros_workflow,
         adapter_route: adapter_route
       }) do
    ensure_supported(:adapter_route, adapter_route, @supported_adapter_routes)
  end

  defp validate_adapter_route(%{adapter_route: adapter_route}) do
    {:error, {:unexpected_adapter_route, adapter_route}}
  end

  defp validate_adapter_route(_decision), do: :ok

  defp unsupported_task_message(%{
         execution_route: execution_route,
         runtime_source: runtime_source,
         transport: transport
       }) do
    route = execution_route |> Atom.to_string() |> String.replace("_", " ")
    runtime = runtime_source |> Atom.to_string() |> String.replace("_", " ")
    transport_label = transport |> Atom.to_string() |> String.replace("_", " ")

    "Unsupported task: no internal #{route} flow is available for #{runtime} using #{transport_label}."
  end

  defp unsupported_task_message(_routing_decision) do
    "Unsupported task: no internal flow is available for this request."
  end

  defp adapter_keys(:runtime, :auto), do: [:runtime]
  defp adapter_keys(route, runtime_source), do: [runtime_source, route]

  defp find_adapter(adapters, keys) do
    Enum.find_value(keys, &Map.get(adapters, &1))
  end
end
