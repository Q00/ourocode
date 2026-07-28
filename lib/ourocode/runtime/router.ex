defmodule Ourocode.Runtime.Router do
  @moduledoc """
  Internal task router for natural-language ourocode task input.

  The router returns both the machine routing decision used by dispatch and a
  compact user-visible result that can be shown in the prompt or dashboard
  before execution starts.
  """

  alias Ourocode.Runtime.RouteClassifier

  defstruct [
    :task_input,
    :execution_route,
    :runtime_source,
    :transport,
    :adapter_route,
    :advanced_shortcut?,
    :reason,
    :route_label,
    :runtime_label,
    :transport_label,
    :message,
    :routing_decision
  ]

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

  @type t :: %__MODULE__{
          task_input: String.t(),
          execution_route: atom(),
          runtime_source: atom(),
          transport: atom(),
          adapter_route: atom() | nil,
          advanced_shortcut?: boolean(),
          reason: atom(),
          route_label: String.t(),
          runtime_label: String.t(),
          transport_label: String.t(),
          message: String.t(),
          routing_decision: routing_decision()
        }

  @doc """
  Routes task text and returns a user-visible routing result.
  """
  @spec route(String.t()) :: {:ok, t()} | {:error, String.t()}
  def route(input) when is_binary(input) do
    case normalize_task_input(input) do
      "" ->
        {:error, "task input cannot be blank"}

      task_input ->
        decision = routing_decision(task_input)
        {:ok, user_visible_result(task_input, decision)}
    end
  end

  def route(_input), do: {:error, "task input must be a string"}

  @doc """
  Returns only the machine routing decision used by runtime dispatch.
  """
  @spec routing_decision(String.t()) :: routing_decision()
  def routing_decision(task_input) when is_binary(task_input) do
    task_input
    |> RouteClassifier.normalize_task_input()
    |> RouteClassifier.routing_decision()
  end

  defp user_visible_result(task_input, decision) do
    %__MODULE__{
      task_input: task_input,
      execution_route: decision.execution_route,
      runtime_source: decision.runtime_source,
      transport: decision.transport,
      adapter_route: Map.get(decision, :adapter_route),
      advanced_shortcut?: decision.advanced_shortcut?,
      reason: decision.reason,
      route_label: route_label(decision.execution_route, Map.get(decision, :adapter_route)),
      runtime_label: runtime_label(decision.runtime_source),
      transport_label: transport_label(decision.transport),
      message: routing_message(decision),
      routing_decision: decision
    }
  end

  defp normalize_task_input(input) do
    RouteClassifier.normalize_task_input(input)
  end

  defp route_label(:runtime, _adapter_route), do: "Runtime session"
  defp route_label(:mcp_flow, _adapter_route), do: "MCP flow"
  defp route_label(:ouroboros_workflow, nil), do: "Ouroboros workflow"

  defp route_label(:ouroboros_workflow, adapter_route) do
    "Ouroboros #{adapter_route_label(adapter_route)}"
  end

  defp adapter_route_label(:interview), do: "interview"
  defp adapter_route_label(:pm), do: "PM interview"
  defp adapter_route_label(:auto), do: "auto"
  defp adapter_route_label(:seed), do: "seed"
  defp adapter_route_label(:run), do: "run"
  defp adapter_route_label(:evolve), do: "evolve"
  defp adapter_route_label(:ralph), do: "Ralph"
  defp adapter_route_label(:status), do: "status"
  defp adapter_route_label(:evaluate), do: "evaluate"
  defp adapter_route_label(:qa), do: "QA"
  defp adapter_route_label(:lateral), do: "lateral"
  defp adapter_route_label(:brownfield), do: "brownfield"
  defp adapter_route_label(:cancel), do: "cancel"
  defp adapter_route_label(:resume_session), do: "resume-session"
  defp adapter_route_label(:update), do: "update"
  defp adapter_route_label(:setup), do: "setup"
  defp adapter_route_label(:publish), do: "publish"
  defp adapter_route_label(:welcome), do: "welcome"
  defp adapter_route_label(:tutorial), do: "tutorial"
  defp adapter_route_label(:help), do: "help"
  defp adapter_route_label(:workflow), do: "workflow"
  defp adapter_route_label(adapter_route), do: Atom.to_string(adapter_route)

  defp runtime_label(:auto), do: "Auto runtime"
  defp runtime_label(:codex), do: "Codex"
  defp runtime_label(:opencode), do: "OpenCode"
  defp runtime_label(:claude_code), do: "Claude Code"
  defp runtime_label(:ouroboros), do: "Ouroboros"
  defp runtime_label(:mcp), do: "MCP"

  defp transport_label(:auto), do: "Auto transport"
  defp transport_label(:stdio), do: "stdio"
  defp transport_label(:streamable_http), do: "streamable HTTP"
  defp transport_label(:sse), do: "SSE"

  defp routing_message(decision) do
    route = route_label(decision.execution_route, Map.get(decision, :adapter_route))
    runtime = runtime_label(decision.runtime_source)
    transport = transport_label(decision.transport)

    "#{route} via #{runtime} using #{transport}"
  end
end
