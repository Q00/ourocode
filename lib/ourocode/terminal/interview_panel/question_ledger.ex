defmodule Ourocode.Terminal.InterviewPanel.QuestionLedger do
  @moduledoc """
  Projects interview turns into selectable question ledger blocks.

  The ledger is data-first so the TUI can render a Grok-like scrollback today
  and wire click or hit-test navigation to the same block ids later.
  """

  alias Ourocode.Runtime.InterviewResponse
  alias Ourocode.Terminal.InterviewPanel.Text

  @max_rendered_blocks 6

  @type block :: %{
          id: String.t(),
          kind: :interview_question,
          index: pos_integer(),
          status: :answered | :pending | :generating,
          selectable?: true,
          selected?: boolean(),
          hovered?: boolean(),
          question: String.t(),
          answer: String.t(),
          reasoning: [String.t()],
          activity: [String.t()],
          choices: [String.t()],
          detail_lines: [String.t()]
        }

  @spec from_interview(map() | nil) :: map()
  def from_interview(interview) when is_map(interview) do
    blocks =
      interview
      |> dialogue_blocks()
      |> append_transition_block(interview)
      |> append_current_question_block(interview)
      |> Enum.reject(&(Map.get(&1, :question, "") == ""))
      |> Enum.with_index(1)
      |> Enum.map(fn {block, index} -> normalize_block(block, index, interview) end)

    selected_id = selected_block_id(interview, blocks)
    blocks = Enum.map(blocks, &select_block(&1, selected_id))

    %{
      kind: :interview_question_ledger,
      selected_block_id: selected_id,
      block_count: length(blocks),
      blocks: blocks
    }
  end

  def from_interview(_interview) do
    %{
      kind: :interview_question_ledger,
      selected_block_id: nil,
      block_count: 0,
      blocks: []
    }
  end

  @spec rows(map() | nil, keyword()) :: [{String.t(), atom()} | :rule]
  def rows(interview, opts \\ []) do
    include_current? = Keyword.get(opts, :include_current?, true)
    expand_selected? = Keyword.get(opts, :expand_selected?, true)

    blocks =
      interview
      |> from_interview()
      |> Map.get(:blocks, [])
      |> maybe_drop_current(include_current?, interview)
      |> Enum.take(-@max_rendered_blocks)
      |> ensure_render_selection()

    if blocks == [] do
      []
    else
      [{"Questions", :dim}] ++ Enum.flat_map(blocks, &block_rows(&1, expand_selected?))
    end
  end

  defp maybe_drop_current(blocks, true, _interview), do: blocks

  defp maybe_drop_current(blocks, false, interview) do
    current_question = interview |> Map.get(:question, "") |> clean_line()

    Enum.reject(blocks, fn block ->
      (current_question != "" and Map.get(block, :question) == current_question) or
        (Map.get(block, :status) in [:pending, :generating] and Map.get(block, :answer, "") == "")
    end)
  end

  defp block_rows(block, expand_selected?) do
    marker = if Map.get(block, :selected?), do: "-", else: "+"
    status = block |> Map.fetch!(:status) |> Atom.to_string()
    index = Map.fetch!(block, :index)
    question = Map.fetch!(block, :question)

    summary =
      {marker <> " [" <> status <> "] Q" <> to_string(index) <> " " <> question,
       block_style(block, status)}

    detail_rows =
      if expand_selected? and Map.get(block, :selected?) do
        block
        |> Map.get(:detail_lines, [])
        |> Enum.map(&detail_row/1)
      else
        []
      end

    [summary | detail_rows] ++ [:rule]
  end

  defp ensure_render_selection([]), do: []

  defp ensure_render_selection(blocks) do
    if Enum.any?(blocks, &Map.get(&1, :selected?)) do
      blocks
    else
      selected = blocks |> List.last() |> Map.get(:id)
      Enum.map(blocks, &select_block(&1, selected))
    end
  end

  defp detail_row({"Question", text}), do: {"Question  " <> text, :warn}
  defp detail_row({"Answer", text}), do: {"Answer  " <> text, :strong}
  defp detail_row({"Reason", text}), do: {"Reason   " <> text, :dim}
  defp detail_row({"MCP", text}), do: {"MCP      " <> text, :dim}
  defp detail_row({"Choice", text}), do: {"Choice   " <> text, :dim}

  defp status_style("answered"), do: :strong
  defp status_style("pending"), do: :warn
  defp status_style("generating"), do: :dim
  defp status_style(_status), do: :dim

  defp block_style(%{selected?: true}, _status), do: :strong
  defp block_style(%{hovered?: true}, _status), do: :warn
  defp block_style(_block, status), do: status_style(status)

  defp dialogue_blocks(interview) do
    interview
    |> Map.get(:dialogue, [])
    |> Enum.reverse()
    |> Enum.reduce({[], nil}, &fold_turn/2)
    |> then(fn {blocks, current} -> finish_block(blocks, current) end)
  end

  defp fold_turn(turn, {blocks, current}) do
    role = turn_role(turn)
    text = turn |> turn_text() |> clean_line()

    cond do
      text == "" ->
        {blocks, current}

      role == :mcp and completion_turn?(text) ->
        {finish_block(blocks, current), nil}

      role == :mcp ->
        {finish_block(blocks, current), new_block(text)}

      role == :user and is_map(current) ->
        {blocks, put_answer(current, text)}

      role == :main and is_map(current) and not internal_main_turn?(text) ->
        {blocks, Map.update(current, :reasoning, [text], &[text | &1])}

      true ->
        {blocks, current}
    end
  end

  defp finish_block(blocks, nil), do: blocks
  defp finish_block(blocks, block), do: blocks ++ [block]

  defp new_block(question) do
    %{
      kind: :interview_question,
      question: question,
      answer: "",
      reasoning: [],
      activity: [],
      choices: [],
      source: :dialogue
    }
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

  defp append_transition_block(blocks, %{waiting: true, last_answer: answer} = interview)
       when is_binary(answer) do
    answer = clean_line(answer)
    question = interview |> Map.get(:last_answered_question, "") |> clean_line()

    if answer == "" or question == "" or duplicate_answered_block?(blocks, question, answer) do
      blocks
    else
      blocks ++
        [
          %{
            kind: :interview_question,
            question: question,
            answer: answer,
            reasoning: global_reasoning(interview),
            activity: global_activity(interview),
            choices: option_lines(Map.get(interview, :last_question_options, [])),
            source: :transition,
            status: :generating
          }
        ]
    end
  end

  defp append_transition_block(blocks, _interview), do: blocks

  defp append_current_question_block(blocks, interview) do
    question = interview |> Map.get(:question, "") |> clean_line()

    cond do
      question == "" ->
        blocks

      Enum.any?(blocks, &(Map.get(&1, :question) == question)) ->
        blocks

      true ->
        blocks ++
          [
            %{
              kind: :interview_question,
              question: question,
              answer: "",
              reasoning: global_reasoning(interview),
              activity: global_activity(interview),
              choices: option_lines(Map.get(interview, :question_options, [])),
              source: :current
            }
          ]
    end
  end

  defp duplicate_answered_block?(blocks, question, answer) do
    Enum.any?(blocks, fn block ->
      Map.get(block, :question) == question and Map.get(block, :answer) == answer
    end)
  end

  defp normalize_block(block, index, interview) do
    block =
      block
      |> Map.put(:id, block_id(index, block))
      |> Map.put(:index, index)
      |> Map.put(:kind, :interview_question)
      |> Map.put(:selectable?, true)
      |> Map.put(
        :reasoning,
        block |> Map.get(:reasoning, []) |> Enum.reverse() |> normalize_lines()
      )
      |> Map.put(:activity, block |> Map.get(:activity, []) |> normalize_activity_lines())
      |> Map.put(:choices, block |> Map.get(:choices, []) |> normalize_lines())

    status = Map.get(block, :status) || inferred_status(block, interview)

    block
    |> Map.put(:status, status)
    |> Map.put(:hovered?, hovered_block?(interview, block))
    |> Map.put(:detail_lines, detail_lines(block, status))
  end

  defp block_id(index, block) do
    seed = Map.get(block, :question, "")
    "interview-q:" <> to_string(index) <> ":" <> short_hash(seed)
  end

  defp short_hash(seed) do
    :crypto.hash(:sha256, seed)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 10)
  end

  defp inferred_status(%{answer: answer}, _interview) when is_binary(answer) and answer != "",
    do: :answered

  defp inferred_status(%{source: :current}, %{waiting: true}), do: :generating
  defp inferred_status(_block, _interview), do: :pending

  defp detail_lines(block, status) do
    question = Map.get(block, :question, "")
    answer = Map.get(block, :answer, "")

    [{"Question", question}]
    |> maybe_append(answer != "", {"Answer", answer})
    |> Kernel.++(reason_detail_lines(Map.get(block, :reasoning, []), status))
    |> Kernel.++(activity_detail_lines(Map.get(block, :activity, [])))
    |> Kernel.++(choice_detail_lines(Map.get(block, :choices, [])))
  end

  defp reason_detail_lines([], :generating),
    do: [{"Reason", "answer accepted; building next choices"}]

  defp reason_detail_lines(lines, _status), do: Enum.map(Enum.take(lines, 3), &{"Reason", &1})

  defp activity_detail_lines(lines), do: Enum.map(Enum.take(lines, 3), &{"MCP", &1})
  defp choice_detail_lines(lines), do: Enum.map(Enum.take(lines, 3), &{"Choice", &1})

  defp maybe_append(lines, true, line), do: lines ++ [line]
  defp maybe_append(lines, false, _line), do: lines

  defp selected_block_id(interview, blocks) do
    explicit =
      Map.get(interview, :selected_question_block_id) ||
        Map.get(interview, "selected_question_block_id")

    cond do
      is_binary(explicit) and Enum.any?(blocks, &(Map.get(&1, :id) == explicit)) ->
        explicit

      blocks == [] ->
        nil

      true ->
        blocks |> List.last() |> Map.get(:id)
    end
  end

  defp select_block(block, selected_id) do
    Map.put(block, :selected?, Map.get(block, :id) == selected_id)
  end

  defp hovered_block?(interview, block) do
    hover_id =
      Map.get(interview, :hovered_question_block_id) ||
        Map.get(interview, "hovered_question_block_id")

    is_binary(hover_id) and Map.get(block, :id) == hover_id
  end

  defp global_reasoning(interview),
    do: interview |> Map.get(:mcp_reasoning, []) |> normalize_lines()

  defp global_activity(interview),
    do: interview |> Map.get(:mcp_activity, []) |> normalize_activity_lines()

  defp option_lines(options) when is_list(options) do
    options
    |> Enum.map(fn
      %{label: label, description: description} ->
        clean_line(to_string(label) <> " - " <> to_string(description))

      %{"label" => label, "description" => description} ->
        clean_line(to_string(label) <> " - " <> to_string(description))

      option ->
        clean_line(option)
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp option_lines(_options), do: []

  defp normalize_lines(lines) when is_list(lines) do
    lines
    |> Enum.map(&clean_line/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_lines(_lines), do: []

  defp normalize_activity_lines(lines) when is_list(lines) do
    lines
    |> Enum.map(&plain_clean_line/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_activity_lines(_lines), do: []

  defp clean_line(text) do
    text
    |> InterviewResponse.clean_markdown()
    |> Text.flatten_line()
  end

  defp plain_clean_line(text), do: Text.flatten_line(text)

  defp put_answer(%{answer: ""} = block, answer), do: Map.put(block, :answer, answer)
  defp put_answer(%{answer: answer} = block, _new_answer) when is_binary(answer), do: block
  defp put_answer(block, answer), do: Map.put(block, :answer, answer)

  defp turn_role(%{role: role}), do: normalize_role(role)
  defp turn_role(%{"role" => role}), do: normalize_role(role)
  defp turn_role(_turn), do: nil

  defp normalize_role(role) when role in [:mcp, "mcp"], do: :mcp
  defp normalize_role(role) when role in [:main, "main"], do: :main
  defp normalize_role(role) when role in [:user, "user"], do: :user
  defp normalize_role(_role), do: nil

  defp turn_text(%{text: text}), do: text
  defp turn_text(%{"text" => text}), do: text
  defp turn_text(_turn), do: ""

  defp internal_main_turn?(text) when is_binary(text) do
    String.contains?(text, [
      "Answer are the answerer/router half",
      "Routing rules (from the interview SKILL)",
      "Tool protocol",
      "Output exactly one directive as the first line",
      "ANSWER [from-code] <answer>",
      "ASK_USER <question for the human>"
    ]) or
      (String.length(text) > 900 and
         String.contains?(text, "ANSWER [from-code]") and
         String.contains?(text, "ASK_USER"))
  end
end
