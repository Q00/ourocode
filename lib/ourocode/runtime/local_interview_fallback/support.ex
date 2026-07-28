defmodule Ourocode.Runtime.LocalInterviewFallback.Support do
  @moduledoc false

  @spec preview_profile(map()) :: map()
  def preview_profile(task_request) do
    route =
      task_request
      |> Map.get(:routing_decision, %{})
      |> Map.get(:adapter_route)

    input = Map.get(task_request, :task_input, "")

    case route do
      :pm -> pm_profile(input)
      _route -> interview_profile(input)
    end
  end

  @spec router_question(map(), [map()], pos_integer()) :: String.t()
  def router_question(profile, turns, round) do
    """
    You are Codex running the visible #{profile.workflow} interview inside ourocode because the MCP daemon is unavailable.

    Original user request:
    #{profile.goal}

    Generate the next adaptive question the human should answer now.
    This is a human-judgment product interview turn, so route it to the user.

    Requirements:
    - Use the ASK_USER directive.
    - Ask only one concrete question at a time.
    - Provide 2 to 4 useful options.
    - Keep labels short and descriptions one line.
    - Adapt to the prior turns; do not repeat answered questions.
    - Do not answer the question yourself.
    - Do not finish the interview in this turn.
    - Round #{round} of at most #{profile.max_rounds}.

    Prior turns:
    #{render_turns(turns)}
    """
  end

  @spec normalize_options(term()) :: [%{label: String.t(), description: String.t()}]
  def normalize_options(options) when is_list(options) do
    options
    |> Enum.map(&normalize_option/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(4)
  end

  def normalize_options(_options), do: []

  @spec clean_text(term()) :: String.t()
  def clean_text(value) when is_binary(value) do
    value
    |> String.replace_invalid("")
    |> String.replace(<<0xFFFD::utf8>>, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  def clean_text(nil), do: ""
  def clean_text(value), do: value |> to_string() |> clean_text()

  @spec usable?(term()) :: boolean()
  def usable?(value) when is_binary(value), do: String.trim(value) != ""
  def usable?(_value), do: false

  @spec continue_interview?(String.t()) :: boolean()
  def continue_interview?(answer) when is_binary(answer) do
    answer
    |> String.downcase()
    |> String.trim()
    |> then(fn text ->
      String.contains?(text, "continue") or String.contains?(text, "keep interviewing") or
        String.contains?(text, "more")
    end)
  end

  @spec seed_ready_summary(String.t()) :: String.t()
  def seed_ready_summary(answer) when is_binary(answer) do
    answer = String.trim(answer)

    cond do
      String.downcase(answer) == "stop for now" ->
        "Stopped the local interview. Run ooo pm again to continue later."

      true ->
        "Ready to generate the seed. Run ooo seed when ready."
    end
  end

  @spec local_error_message(term()) :: String.t()
  def local_error_message({:model_not_ready, {:needs_auth, hint}}),
    do: "active model needs login; run " <> to_string(hint)

  def local_error_message({:model_not_ready, status}),
    do: "active model is not ready: " <> inspect(status)

  def local_error_message({:model_stream_failed, reason}),
    do: "active model call failed: " <> inspect(reason)

  def local_error_message({:unexpected_router_answer, source, payload}),
    do: "Codex answered instead of asking a user question: #{inspect(source)} #{inspect(payload)}"

  def local_error_message(reason),
    do: "Codex did not produce a usable interview question: " <> inspect(reason)

  defp pm_profile(input) do
    goal = workflow_goal(input, "ooo pm")

    %{
      workflow: "PM",
      goal: goal,
      max_rounds: 6
    }
  end

  defp interview_profile(input) do
    goal = workflow_goal(input, "ooo interview")

    %{
      workflow: "Socratic",
      goal: goal,
      max_rounds: 5
    }
  end

  defp workflow_goal(input, prefix) do
    input
    |> to_string()
    |> String.trim()
    |> remove_prefix(prefix)
    |> case do
      "" -> "this work"
      goal -> goal
    end
  end

  defp remove_prefix(input, prefix) do
    if String.starts_with?(String.downcase(input), prefix) do
      input
      |> String.slice(String.length(prefix)..-1//1)
      |> String.trim()
    else
      input
    end
  end

  defp render_turns([]), do: "None yet."

  defp render_turns(turns) do
    turns
    |> Enum.with_index(1)
    |> Enum.map(fn {turn, index} ->
      question = turn |> Map.get(:question, "") |> to_string()
      answer = turn |> Map.get(:answer, "") |> to_string()
      "#{index}. Q: #{question}\n   A: #{answer}"
    end)
    |> Enum.join("\n")
  end

  defp normalize_option(option) when is_map(option) do
    with {label, description} <- option_fields(option),
         label <- clean_text(label),
         description <- clean_text(description),
         true <- usable?(label) and usable?(description) do
      %{label: label, description: description}
    else
      _invalid -> nil
    end
  end

  defp normalize_option(_option), do: nil

  defp option_fields(%{label: label, description: description}), do: {label, description}
  defp option_fields(%{"label" => label, "description" => description}), do: {label, description}
  defp option_fields(_option), do: nil
end
