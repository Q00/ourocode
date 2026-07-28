defmodule Ourocode.Runtime.RouterTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.Router

  test "routes supported task input with user-visible result and machine decision" do
    assert {:ok,
            %Router{
              task_input: "MCP tools/call over streamable HTTP",
              execution_route: :mcp_flow,
              runtime_source: :mcp,
              transport: :streamable_http,
              route_label: "MCP flow",
              runtime_label: "MCP",
              transport_label: "streamable HTTP",
              message: "MCP flow via MCP using streamable HTTP",
              routing_decision: %{
                kind: :mcp_flow,
                execution_route: :mcp_flow,
                runtime_source: :mcp,
                transport: :streamable_http,
                requires_command_syntax?: false,
                advanced_shortcut?: true,
                reason: :mcp_flow_terms
              }
            }} = Router.route("  MCP tools/call over streamable HTTP  ")
  end

  test "routes Ouroboros workflow intent with visible adapter label" do
    assert {:ok,
            %Router{
              execution_route: :ouroboros_workflow,
              runtime_source: :ouroboros,
              adapter_route: :evolve,
              route_label: "Ouroboros evolve",
              message: "Ouroboros evolve via Ouroboros using Auto transport",
              routing_decision: %{
                adapter_route: :evolve,
                advanced_shortcut?: false,
                requires_command_syntax?: false
              }
            }} = Router.route("Run Ouroboros workflow evolve for plugin renderer")
  end

  test "routes natural SaaS product goals to the visible PM interview" do
    assert {:ok,
            %Router{
              execution_route: :ouroboros_workflow,
              runtime_source: :ouroboros,
              adapter_route: :pm,
              route_label: "Ouroboros PM interview",
              message: "Ouroboros PM interview via Ouroboros using Auto transport",
              routing_decision: %{
                adapter_route: :pm,
                reason: :product_goal_terms,
                advanced_shortcut?: false,
                requires_command_syntax?: false
              }
            }} = Router.route("카드 뉴스를 만들어주는 나만의 SaaS를 만들고 싶어")
  end

  test "allows explicit diagnostics and test commands only as advanced shortcuts" do
    assert {:ok,
            %Router{
              execution_route: :runtime,
              runtime_source: :auto,
              transport: :stdio,
              advanced_shortcut?: true,
              routing_decision: %{
                kind: :runtime,
                execution_route: :runtime,
                runtime_source: :auto,
                transport: :stdio,
                requires_command_syntax?: false,
                advanced_shortcut?: true,
                reason: :explicit_diagnostics_shortcut
              }
            }} = Router.route("diagnostics streams stdio")

    assert {:ok,
            %Router{
              execution_route: :runtime,
              runtime_source: :auto,
              transport: :sse,
              advanced_shortcut?: true,
              routing_decision: %{
                requires_command_syntax?: false,
                reason: :explicit_test_shortcut
              }
            }} = Router.route("test:transports sse seq stream")
  end

  test "plain diagnostic requests remain product representative natural-language tasks" do
    assert {:ok,
            %Router{
              execution_route: :runtime,
              runtime_source: :auto,
              advanced_shortcut?: false,
              routing_decision: %{
                requires_command_syntax?: false,
                advanced_shortcut?: false,
                reason: :default_natural_language_runtime
              }
            }} = Router.route("Run diagnostics for stream health")
  end

  test "rejects blank or non-string routing input" do
    assert Router.route(" \n\t ") == {:error, "task input cannot be blank"}
    assert Router.route(nil) == {:error, "task input must be a string"}
  end
end
