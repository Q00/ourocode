defmodule Ourocode.Runtime.RouteClassifier do
  @moduledoc """
  Classifies normalized task input into runtime dispatch decisions.

  `Ourocode.Runtime.Router` owns user-visible presentation. This module owns
  tokenization, shortcut detection, transport hints, and adapter route choice.
  """

  alias Ourocode.Runtime.RouteTerms

  @type routing_decision :: %{
          required(:kind) => :runtime | :ouroboros_workflow | :mcp_flow,
          required(:execution_route) => :runtime | :ouroboros_workflow | :mcp_flow,
          required(:runtime_source) =>
            :auto | :codex | :opencode | :claude_code | :ouroboros | :mcp,
          required(:transport) => :auto | :stdio | :streamable_http | :sse,
          required(:requires_command_syntax?) => false,
          required(:advanced_shortcut?) => boolean(),
          required(:reason) => atom(),
          optional(:adapter_route) => atom()
        }

  @doc """
  Normalizes task input before classification.
  """
  @spec normalize_task_input(String.t()) :: String.t()
  def normalize_task_input(input) when is_binary(input) do
    RouteTerms.normalize(input)
  end

  @doc """
  Returns the machine routing decision used by runtime dispatch.
  """
  @spec routing_decision(String.t()) :: routing_decision()
  def routing_decision(task_input) when is_binary(task_input) do
    task_input
    |> classify_route()
    |> to_routing_decision()
  end

  @doc """
  Tokenizes normalized route input for keyword matching.
  """
  @spec route_tokens(String.t()) :: [String.t()]
  def route_tokens(task_input) when is_binary(task_input) do
    RouteTerms.tokens(task_input)
  end

  defp to_routing_decision(route) do
    %{
      kind: route.kind,
      execution_route: route.kind,
      runtime_source: route.runtime_source,
      transport: route.transport,
      requires_command_syntax?: false,
      advanced_shortcut?: route.advanced_shortcut?,
      reason: route.reason,
      adapter_route: route.adapter_route
    }
    |> drop_nil_values()
  end

  defp classify_route(task_input) do
    tokens = RouteTerms.tokens(task_input)
    first = List.first(tokens)
    ouroboros_adapter_route = RouteTerms.ouroboros_adapter_route(tokens)

    cond do
      first in ["ooo", "ouroboros"] ->
        route(
          :ouroboros_workflow,
          :ouroboros,
          RouteTerms.transport_from_tokens(tokens),
          true,
          :explicit_ouroboros_shortcut,
          ouroboros_adapter_route
        )

      RouteTerms.explicit_diagnostics_shortcut?(tokens) ->
        route(
          :runtime,
          :auto,
          RouteTerms.transport_from_tokens(tokens),
          true,
          :explicit_diagnostics_shortcut
        )

      RouteTerms.explicit_test_shortcut?(tokens) ->
        route(
          :runtime,
          :auto,
          RouteTerms.transport_from_tokens(tokens),
          true,
          :explicit_test_shortcut
        )

      first == "codex" ->
        route(
          :runtime,
          :codex,
          RouteTerms.transport_from_tokens(tokens),
          true,
          :explicit_codex_shortcut
        )

      first == "opencode" ->
        route(
          :runtime,
          :opencode,
          RouteTerms.transport_from_tokens(tokens),
          true,
          :explicit_opencode_shortcut
        )

      first in ["claude-code", "claude"] ->
        route(
          :runtime,
          :claude_code,
          RouteTerms.transport_from_tokens(tokens),
          true,
          :explicit_claude_code_shortcut
        )

      RouteTerms.mcp_flow?(tokens) ->
        route(
          :mcp_flow,
          :mcp,
          RouteTerms.transport_from_tokens(tokens),
          RouteTerms.explicit_mcp_shortcut?(tokens),
          :mcp_flow_terms
        )

      RouteTerms.ouroboros_workflow?(tokens) ->
        route(
          :ouroboros_workflow,
          :ouroboros,
          RouteTerms.transport_from_tokens(tokens),
          false,
          :ouroboros_workflow_terms,
          ouroboros_adapter_route
        )

      RouteTerms.product_goal?(task_input, tokens) ->
        route(
          :ouroboros_workflow,
          :ouroboros,
          RouteTerms.transport_from_tokens(tokens),
          false,
          :product_goal_terms,
          :pm
        )

      true ->
        route(
          :runtime,
          :auto,
          RouteTerms.transport_from_tokens(tokens),
          false,
          :default_natural_language_runtime
        )
    end
  end

  defp route(kind, runtime_source, transport, advanced_shortcut?, reason, adapter_route \\ nil) do
    %{
      kind: kind,
      runtime_source: runtime_source,
      transport: transport,
      advanced_shortcut?: advanced_shortcut?,
      reason: reason,
      adapter_route: adapter_route
    }
  end

  defp drop_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
