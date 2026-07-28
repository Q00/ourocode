defmodule Ourocode.Terminal.InterviewPanel.Dialogue do
  @moduledoc false

  alias Ourocode.Runtime.InterviewResponse
  alias Ourocode.Terminal.InterviewPanel.Text

  @dialogue_tail 6

  @spec rows(map() | nil, boolean()) :: [{String.t(), atom()} | :rule]
  def rows(interview_state, drop_trailing_mcp?) do
    turns =
      interview_state
      |> dialogue()
      |> Enum.reverse()
      |> maybe_drop_trailing_mcp(drop_trailing_mcp?)

    turns
    |> Enum.take(-@dialogue_tail)
    |> Enum.reject(&internal_turn?/1)
    |> Enum.map(&row/1)
    |> Enum.intersperse(:rule)
  end

  defp dialogue(%{} = interview_state), do: Map.get(interview_state, :dialogue, [])
  defp dialogue(_interview_state), do: []

  defp maybe_drop_trailing_mcp(turns, true) do
    case List.last(turns) do
      %{role: :mcp} -> Enum.drop(turns, -1)
      _other -> turns
    end
  end

  defp maybe_drop_trailing_mcp(turns, _drop?), do: turns

  defp internal_turn?(%{role: :main, text: text}) when is_binary(text),
    do: leaked_router_prompt?(text) or String.starts_with?(String.trim(text), "→ asking you:")

  defp internal_turn?(%{role: :mcp, text: text}) when is_binary(text),
    do: completion_turn?(text)

  defp internal_turn?(_turn), do: false

  defp row(%{role: role, text: text}) do
    {label, style} =
      case role do
        :mcp -> {"Question", :warn}
        :main -> {"MAIN", :ok}
        :user -> user_row_label(text)
        _other -> {"TURN", :dim}
      end

    {label <> "  " <> (text |> InterviewResponse.clean_markdown() |> Text.flatten_line()), style}
  end

  defp user_row_label(text) when is_binary(text) do
    if workflow_command?(text), do: {"Goal", :strong}, else: {"Answer", :strong}
  end

  defp user_row_label(_text), do: {"Answer", :strong}

  defp workflow_command?(text) do
    case String.trim_leading(text) do
      "ooo" -> true
      "ooo" <> rest -> String.match?(rest, ~r/^\s/)
      _other -> false
    end
  end

  defp completion_turn?(text) do
    text = String.downcase(text)

    String.contains?(text, "interview complete") or
      String.contains?(text, "interview completed") or
      String.contains?(text, "local interview fallback complete") or
      String.contains?(text, "ai interview fallback complete") or
      String.contains?(text, "ready for seed generation") or
      String.contains?(text, "ooo seed")
  end

  defp leaked_router_prompt?(text) when is_binary(text) do
    flat = String.replace(text, ~r/\s+/, " ")

    String.contains?(flat, [
      "Answer are the answerer/router half",
      "Routing rules (from the interview SKILL)",
      "Tool protocol",
      "Output exactly one directive as the first line",
      "ANSWER [from-code] <answer>",
      "ASK_USER <question for the human>"
    ]) or
      (String.length(flat) > 900 and
         String.contains?(flat, "ANSWER [from-code]") and
         String.contains?(flat, "ASK_USER"))
  end

  defp leaked_router_prompt?(_text), do: false
end
