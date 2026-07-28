defmodule Ourocode.Runtime.RouteTermsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.RouteTerms

  test "normalizes and tokenizes route input" do
    assert RouteTerms.normalize("  MCP\n tools/call\t over HTTP  ") ==
             "MCP tools/call over HTTP"

    assert RouteTerms.tokens("MCP tools/call over streamable HTTP!") == [
             "mcp",
             "tools/call",
             "over",
             "streamable",
             "http"
           ]
  end

  test "detects mcp flow terms and explicit mcp shortcuts" do
    assert RouteTerms.mcp_flow?(["please", "mcp:stdio"])
    assert RouteTerms.mcp_flow?(["json-rpc"])
    assert RouteTerms.explicit_mcp_shortcut?(["tools/call", "list"])
    refute RouteTerms.explicit_mcp_shortcut?(["please", "mcp"])
  end

  test "detects explicit runtime shortcuts" do
    assert RouteTerms.explicit_diagnostics_shortcut?(["diagnostics:streams"])
    assert RouteTerms.explicit_test_shortcut?(["test:transport"])
    refute RouteTerms.explicit_diagnostics_shortcut?(["please", "diagnostics"])
    refute RouteTerms.explicit_test_shortcut?(["please", "test:transport"])
  end

  test "detects ouroboros workflow terms and adapter routes" do
    assert RouteTerms.ouroboros_workflow?(["please", "ouroboros:evolve"])
    assert RouteTerms.ouroboros_adapter_route(["ooo", "auto", "build", "it"]) == :auto
    assert RouteTerms.ouroboros_adapter_route(["ooo", "interview", "clarify", "it"]) == :interview
    assert RouteTerms.ouroboros_adapter_route(["ooo", "pm", "build", "onboarding"]) == :pm
    assert RouteTerms.ouroboros_adapter_route(["please", "ouroboros:pm"]) == :pm
    assert RouteTerms.ouroboros_adapter_route(["ooo", "run", "seed_path=seed.md"]) == :run
    assert RouteTerms.ouroboros_adapter_route(["ouroboros", "execute", "seed.md"]) == :run
    assert RouteTerms.ouroboros_adapter_route(["please", "ralph"]) == :ralph
    assert RouteTerms.ouroboros_adapter_route(["ooo", "qa", "file.md"]) == :qa
    assert RouteTerms.ouroboros_adapter_route(["quality", "check"]) == :qa
    assert RouteTerms.ouroboros_adapter_route(["ooo", "lateral", "hacker"]) == :lateral
    assert RouteTerms.ouroboros_adapter_route(["think", "sideways"]) == :lateral
    assert RouteTerms.ouroboros_adapter_route(["ooo", "brownfield", "scan"]) == :brownfield
    assert RouteTerms.ouroboros_adapter_route(["ooo", "cancel", "execution", "exec-1"]) == :cancel
    assert RouteTerms.ouroboros_adapter_route(["ooo", "resume-session"]) == :resume_session
    assert RouteTerms.ouroboros_adapter_route(["ooo", "update"]) == :update
    assert RouteTerms.ouroboros_adapter_route(["ooo", "setup"]) == :setup
    assert RouteTerms.ouroboros_adapter_route(["ooo", "publish", "seed.yaml"]) == :publish
    assert RouteTerms.ouroboros_adapter_route(["ooo", "welcome"]) == :welcome
    assert RouteTerms.ouroboros_adapter_route(["ooo", "tutorial"]) == :tutorial
    assert RouteTerms.ouroboros_adapter_route(["ooo", "help"]) == :help
    assert RouteTerms.ouroboros_adapter_route(["ooo", "status", "session", "sess-1"]) == :status
    assert RouteTerms.ouroboros_adapter_route(["session", "status"]) == :status

    assert RouteTerms.ouroboros_adapter_route(["ooo", "evaluate", "session", "sess-1"]) ==
             :evaluate

    assert RouteTerms.ouroboros_adapter_route(["please", "workflow"]) == :workflow

    # No explicit action token: ambiguous goals fall back to the Socratic
    # interview instead of the previously unmapped :workflow route.
    assert RouteTerms.ouroboros_adapter_route(["please", "other"]) == :interview
    assert RouteTerms.ouroboros_adapter_route(["ooo", "build", "me", "a", "thing"]) == :interview
  end

  test "detects natural product goals for PM interview routing" do
    input = "카드 뉴스를 만들어주는 나만의 SaaS를 만들고 싶어"

    assert RouteTerms.product_goal?(input, RouteTerms.tokens(input))
    assert RouteTerms.product_goal?("Build a SaaS that turns blog posts into card news", [])

    refute RouteTerms.product_goal?("Fix the renderer state bug", ["fix", "the", "renderer"])
    refute RouteTerms.product_goal?("git status", ["git", "status"])
  end

  test "does not treat plain run commands as implicit Ouroboros workflow" do
    refute RouteTerms.ouroboros_workflow?(["run", "the", "unit", "tests"])
    refute RouteTerms.ouroboros_workflow?(["git", "status"])
    assert RouteTerms.ouroboros_adapter_route(["ooo", "run", "seed_path=seed.md"]) == :run
  end

  test "extracts transport hints from tokens" do
    assert RouteTerms.transport_from_tokens(["mcp:stdio"]) == :stdio
    assert RouteTerms.transport_from_tokens(["sse"]) == :sse
    assert RouteTerms.transport_from_tokens(["streamable-http"]) == :streamable_http
    assert RouteTerms.transport_from_tokens(["http"]) == :streamable_http
    assert RouteTerms.transport_from_tokens(["plain", "prompt"]) == :auto
  end
end
