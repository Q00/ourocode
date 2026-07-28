defmodule Ourocode.Runtime.RouteClassifierTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.RouteClassifier

  test "normalizes task input and tokenizes route terms" do
    assert RouteClassifier.normalize_task_input("  MCP\n tools/call\t over HTTP  ") ==
             "MCP tools/call over HTTP"

    assert RouteClassifier.route_tokens("MCP tools/call over streamable HTTP!") == [
             "mcp",
             "tools/call",
             "over",
             "streamable",
             "http"
           ]
  end

  test "classifies MCP flows and transport hints" do
    assert RouteClassifier.routing_decision("MCP tools/call over streamable HTTP") == %{
             kind: :mcp_flow,
             execution_route: :mcp_flow,
             runtime_source: :mcp,
             transport: :streamable_http,
             requires_command_syntax?: false,
             advanced_shortcut?: true,
             reason: :mcp_flow_terms
           }
  end

  test "classifies explicit Ouroboros workflow shortcuts with adapter route" do
    assert RouteClassifier.routing_decision("ooo auto improve onboarding") == %{
             kind: :ouroboros_workflow,
             execution_route: :ouroboros_workflow,
             runtime_source: :ouroboros,
             transport: :auto,
             requires_command_syntax?: false,
             advanced_shortcut?: true,
             reason: :explicit_ouroboros_shortcut,
             adapter_route: :auto
           }

    assert RouteClassifier.routing_decision("ooo run seed_path=seed.md") == %{
             kind: :ouroboros_workflow,
             execution_route: :ouroboros_workflow,
             runtime_source: :ouroboros,
             transport: :auto,
             requires_command_syntax?: false,
             advanced_shortcut?: true,
             reason: :explicit_ouroboros_shortcut,
             adapter_route: :run
           }

    assert %{adapter_route: :pm} =
             RouteClassifier.routing_decision("ooo pm build onboarding")

    assert %{adapter_route: :interview} =
             RouteClassifier.routing_decision("ooo interview clarify cleanup policy")

    # No explicit action token falls back to the interview flow.
    assert %{adapter_route: :interview, execution_route: :ouroboros_workflow} =
             RouteClassifier.routing_decision("ooo build me a thing")

    assert %{adapter_route: :status} =
             RouteClassifier.routing_decision("ooo status session sess-123")

    assert %{adapter_route: :evaluate} =
             RouteClassifier.routing_decision("ooo evaluate session sess-123")

    assert %{adapter_route: :qa} =
             RouteClassifier.routing_decision("ooo qa artifact.md")

    assert %{adapter_route: :lateral} =
             RouteClassifier.routing_decision("ooo lateral hacker simplify state")

    assert %{adapter_route: :brownfield} =
             RouteClassifier.routing_decision("ooo brownfield scan")

    assert %{adapter_route: :cancel} =
             RouteClassifier.routing_decision("ooo cancel execution exec-1")

    assert %{adapter_route: :resume_session} =
             RouteClassifier.routing_decision("ooo resume-session")

    assert %{adapter_route: :publish} =
             RouteClassifier.routing_decision("ooo publish seed.yaml")
  end

  test "classifies natural Ouroboros workflow terms" do
    assert %{
             execution_route: :ouroboros_workflow,
             adapter_route: :evolve,
             advanced_shortcut?: false,
             reason: :ouroboros_workflow_terms
           } = RouteClassifier.routing_decision("Run Ouroboros workflow evolve")
  end

  test "classifies natural product SaaS goals as PM interview workflow" do
    assert %{
             kind: :ouroboros_workflow,
             execution_route: :ouroboros_workflow,
             runtime_source: :ouroboros,
             transport: :auto,
             requires_command_syntax?: false,
             advanced_shortcut?: false,
             reason: :product_goal_terms,
             adapter_route: :pm
           } = RouteClassifier.routing_decision("카드 뉴스를 만들어주는 나만의 SaaS를 만들고 싶어")
  end

  test "classifies explicit runtime shortcuts" do
    assert %{
             execution_route: :runtime,
             runtime_source: :codex,
             advanced_shortcut?: true,
             reason: :explicit_codex_shortcut
           } = RouteClassifier.routing_decision("codex fix failing tests")

    assert %{
             execution_route: :runtime,
             runtime_source: :claude_code,
             reason: :explicit_claude_code_shortcut
           } = RouteClassifier.routing_decision("claude inspect logs")
  end

  test "defaults natural language to auto runtime" do
    assert RouteClassifier.routing_decision("Fix the renderer state bug") == %{
             kind: :runtime,
             execution_route: :runtime,
             runtime_source: :auto,
             transport: :auto,
             requires_command_syntax?: false,
             advanced_shortcut?: false,
             reason: :default_natural_language_runtime
           }

    assert %{execution_route: :runtime} = RouteClassifier.routing_decision("git status")
  end
end
