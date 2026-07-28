defmodule Ourocode.Runtime.RouteTerms do
  @moduledoc """
  Token and keyword matching helpers for runtime route classification.
  """

  @spec normalize(String.t()) :: String.t()
  def normalize(input) when is_binary(input) do
    input
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
  end

  @spec tokens(String.t()) :: [String.t()]
  def tokens(task_input) when is_binary(task_input) do
    task_input
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_.:\-\/]+/u, " ")
    |> String.split(" ", trim: true)
  end

  @spec mcp_flow?([String.t()]) :: boolean()
  def mcp_flow?(tokens) when is_list(tokens) do
    Enum.any?(tokens, &(&1 in ["mcp", "tools/call", "tools.call", "json-rpc", "jsonrpc"])) or
      Enum.any?(tokens, &String.starts_with?(&1, "mcp:"))
  end

  @spec explicit_mcp_shortcut?([String.t()]) :: boolean()
  def explicit_mcp_shortcut?([first | _tokens]) do
    first in ["mcp", "tools/call", "tools.call"]
  end

  def explicit_mcp_shortcut?(_tokens), do: false

  @spec explicit_diagnostics_shortcut?([String.t()]) :: boolean()
  def explicit_diagnostics_shortcut?([first | _tokens]) do
    first in ["diag", "diagnostics", "diagnostics:runtime", "diagnostics:streams"]
  end

  def explicit_diagnostics_shortcut?(_tokens), do: false

  @spec explicit_test_shortcut?([String.t()]) :: boolean()
  def explicit_test_shortcut?([first | _tokens]) do
    first in ["test:transport", "test:transports", "tests:transport", "tests:transports"]
  end

  def explicit_test_shortcut?(_tokens), do: false

  @spec ouroboros_workflow?([String.t()]) :: boolean()
  def ouroboros_workflow?(tokens) when is_list(tokens) do
    Enum.any?(
      tokens,
      &(&1 in [
          "auto",
          "interview",
          "pm",
          "seed",
          "evolve",
          "ralph",
          "qa",
          "lateral",
          "unstuck",
          "brownfield",
          "cancel",
          "resume-session",
          "update",
          "setup",
          "publish",
          "welcome",
          "tutorial",
          "evaluate",
          "workflow"
        ])
    ) or status_terms?(tokens) or quality_terms?(tokens) or lateral_terms?(tokens) or
      direct_terms?(tokens) or
      Enum.any?(tokens, &String.starts_with?(&1, "ouroboros:"))
  end

  @spec product_goal?(String.t(), [String.t()]) :: boolean()
  def product_goal?(input, tokens) when is_binary(input) and is_list(tokens) do
    normalized = input |> normalize() |> String.downcase()
    route_tokens = if tokens == [], do: tokens(normalized), else: tokens

    product_term?(normalized, route_tokens) and creation_intent?(normalized, route_tokens)
  end

  @spec ouroboros_adapter_route([String.t()]) ::
          :auto
          | :interview
          | :pm
          | :seed
          | :evolve
          | :ralph
          | :run
          | :status
          | :evaluate
          | :qa
          | :lateral
          | :brownfield
          | :cancel
          | :resume_session
          | :update
          | :setup
          | :publish
          | :welcome
          | :tutorial
          | :help
          | :workflow
  def ouroboros_adapter_route(tokens) when is_list(tokens) do
    cond do
      Enum.any?(tokens, &(&1 in ["auto", "ouroboros:auto"])) ->
        :auto

      Enum.any?(tokens, &(&1 in ["interview", "ouroboros:interview"])) ->
        :interview

      # PM requests run the interview loop but call the dedicated
      # `ouroboros_pm_interview` tool instead of `ouroboros_interview`.
      Enum.any?(tokens, &(&1 in ["pm", "ouroboros:pm"])) ->
        :pm

      Enum.any?(tokens, &(&1 in ["seed", "ouroboros:seed"])) ->
        :seed

      Enum.any?(tokens, &(&1 in ["evolve", "ouroboros:evolve"])) ->
        :evolve

      Enum.any?(tokens, &(&1 in ["ralph", "ouroboros:ralph"])) ->
        :ralph

      lateral_terms?(tokens) ->
        :lateral

      quality_terms?(tokens) ->
        :qa

      Enum.any?(tokens, &(&1 in ["brownfield", "ouroboros:brownfield"])) ->
        :brownfield

      direct_route = direct_adapter_route(tokens) ->
        direct_route

      explicit_ouroboros_run?(tokens) ->
        :run

      status_terms?(tokens) ->
        :status

      Enum.any?(tokens, &(&1 in ["evaluate", "eval", "ouroboros:evaluate"])) ->
        :evaluate

      Enum.any?(tokens, &(&1 in ["workflow", "ouroboros:workflow"])) ->
        :workflow

      # Conservative fallback: an `ooo <natural language>` request with no
      # explicit action token is an ambiguous goal, so it is absorbed into the
      # Socratic interview flow (the product intent is to clarify vague
      # requirements) instead of an unmapped :workflow route that previously
      # always dispatch-failed.
      true ->
        :interview
    end
  end

  @spec transport_from_tokens([String.t()]) :: :auto | :stdio | :streamable_http | :sse
  def transport_from_tokens(tokens) when is_list(tokens) do
    cond do
      Enum.any?(tokens, &(&1 in ["stdio", "mcp:stdio"])) ->
        :stdio

      Enum.any?(tokens, &(&1 in ["sse", "mcp:sse"])) ->
        :sse

      Enum.any?(tokens, &(&1 in ["streamable-http", "streamable_http", "http", "mcp:http"])) ->
        :streamable_http

      true ->
        :auto
    end
  end

  defp explicit_ouroboros_run?(["ooo", action | _tokens]) when action in ["run", "execute"],
    do: true

  defp explicit_ouroboros_run?(["ouroboros", action | _tokens])
       when action in ["run", "execute"],
       do: true

  defp explicit_ouroboros_run?(tokens),
    do: Enum.any?(tokens, &(&1 in ["ouroboros:run", "ouroboros:execute"]))

  defp product_term?(normalized, tokens) do
    Enum.any?(tokens, &(&1 in ["saas", "product", "service", "app", "mvp", "startup"])) or
      String.contains?(normalized, ["서비스", "제품", "앱", "어플", "스타트업"])
  end

  defp creation_intent?(normalized, tokens) do
    Enum.any?(tokens, &(&1 in ["build", "create", "make", "design", "launch", "plan", "idea"])) or
      String.contains?(normalized, ["만들", "기획", "제작", "출시", "런칭", "구상"])
  end

  defp status_terms?(["ooo", "status" | _tokens]), do: true
  defp status_terms?(["ouroboros", "status" | _tokens]), do: true

  defp status_terms?(tokens) do
    Enum.any?(tokens, &(&1 in ["ouroboros:status", "drift", "drifting"])) or
      Enum.chunk_every(tokens, 2, 1, :discard)
      |> Enum.any?(fn
        ["session", "status"] -> true
        ["status", "session"] -> true
        _other -> false
      end)
  end

  defp quality_terms?(["ooo", action | _tokens]) when action in ["qa", "quality"], do: true
  defp quality_terms?(["ouroboros", action | _tokens]) when action in ["qa", "quality"], do: true

  defp quality_terms?(tokens) do
    Enum.any?(tokens, &(&1 in ["ouroboros:qa"])) or
      Enum.chunk_every(tokens, 2, 1, :discard)
      |> Enum.any?(fn
        ["qa", "check"] -> true
        ["quality", "check"] -> true
        _other -> false
      end)
  end

  defp lateral_terms?(["ooo", action | _tokens]) when action in ["lateral", "unstuck"],
    do: true

  defp lateral_terms?(["ouroboros", action | _tokens]) when action in ["lateral", "unstuck"],
    do: true

  defp lateral_terms?(tokens) do
    Enum.any?(tokens, &(&1 in ["ouroboros:unstuck", "ouroboros:lateral"])) or
      Enum.chunk_every(tokens, 2, 1, :discard)
      |> Enum.any?(fn
        ["think", "sideways"] -> true
        ["i", "stuck"] -> true
        ["im", "stuck"] -> true
        _other -> false
      end)
  end

  defp direct_terms?(tokens), do: not is_nil(direct_adapter_route(tokens))

  defp direct_adapter_route(["ooo", action | _tokens]), do: explicit_direct_action(action)
  defp direct_adapter_route(["ouroboros", action | _tokens]), do: explicit_direct_action(action)

  defp direct_adapter_route(tokens) do
    cond do
      Enum.any?(tokens, &(&1 in ["ouroboros:cancel"])) -> :cancel
      Enum.any?(tokens, &(&1 in ["ouroboros:resume-session"])) -> :resume_session
      Enum.any?(tokens, &(&1 in ["ouroboros:update"])) -> :update
      Enum.any?(tokens, &(&1 in ["ouroboros:setup"])) -> :setup
      Enum.any?(tokens, &(&1 in ["ouroboros:publish"])) -> :publish
      Enum.any?(tokens, &(&1 in ["ouroboros:welcome"])) -> :welcome
      Enum.any?(tokens, &(&1 in ["ouroboros:tutorial"])) -> :tutorial
      Enum.any?(tokens, &(&1 in ["ouroboros:help"])) -> :help
      Enum.chunk_every(tokens, 2, 1, :discard) |> Enum.any?(&cancel_phrase?/1) -> :cancel
      Enum.chunk_every(tokens, 2, 1, :discard) |> Enum.any?(&resume_phrase?/1) -> :resume_session
      Enum.chunk_every(tokens, 2, 1, :discard) |> Enum.any?(&update_phrase?/1) -> :update
      Enum.chunk_every(tokens, 2, 1, :discard) |> Enum.any?(&publish_phrase?/1) -> :publish
      true -> nil
    end
  end

  defp explicit_direct_action("cancel"), do: :cancel
  defp explicit_direct_action("resume-session"), do: :resume_session
  defp explicit_direct_action("update"), do: :update
  defp explicit_direct_action("setup"), do: :setup
  defp explicit_direct_action("publish"), do: :publish
  defp explicit_direct_action("welcome"), do: :welcome
  defp explicit_direct_action("tutorial"), do: :tutorial
  defp explicit_direct_action("help"), do: :help
  defp explicit_direct_action(_action), do: nil

  defp cancel_phrase?(["cancel", "execution"]), do: true
  defp cancel_phrase?(["abort", "execution"]), do: true
  defp cancel_phrase?(["stop", "running"]), do: true
  defp cancel_phrase?(_tokens), do: false

  defp resume_phrase?(["in-flight", "sessions"]), do: true
  defp resume_phrase?(["lost", "ouroboros"]), do: true
  defp resume_phrase?(["mcp", "disconnected"]), do: true
  defp resume_phrase?(_tokens), do: false

  defp update_phrase?(["update", "ouroboros"]), do: true
  defp update_phrase?(["upgrade", "ouroboros"]), do: true
  defp update_phrase?(_tokens), do: false

  defp publish_phrase?(["publish", "github"]), do: true
  defp publish_phrase?(["publish", "to"]), do: true
  defp publish_phrase?(["seed", "issues"]), do: true
  defp publish_phrase?(_tokens), do: false
end
