defmodule Ourocode.Terminal.InterviewPanel do
  @moduledoc """
  Pure text rendering helpers for interview, wonderTool, and MCP activity panes.
  """

  alias Ourocode.Terminal.InterviewPanel.Dialogue
  alias Ourocode.Terminal.InterviewPanel.Hints
  alias Ourocode.Terminal.InterviewPanel.QuestionLedger
  alias Ourocode.Terminal.InterviewPanel.Status
  alias Ourocode.Terminal.InterviewPanel.Text
  alias Ourocode.Terminal.InterviewPanel.WonderPicker
  alias Ourocode.Terminal.InterviewLiveState

  @spec dialogue_rows(map(), boolean()) :: [{String.t(), atom()} | :rule]
  def dialogue_rows(result, drop_trailing_mcp?) do
    result
    |> interview_state()
    |> Dialogue.rows(drop_trailing_mcp?)
  end

  @spec interview_working_lines(map(), integer()) :: [String.t()]
  def interview_working_lines(result, tick) do
    iv = interview_state(result)
    trace = if iv, do: List.first(Map.get(iv, :router, [])), else: nil

    if paused?(result) or waiting_for_user?(iv) or interview_error?(iv) or
         active_question_waiting?(iv) or completed_without_visible_answer?(iv, trace) do
      []
    else
      [working_line(tick, trace, waiting_elapsed_seconds(iv))]
    end
  end

  @spec wonder_picker_lines(map(), map() | nil) :: [String.t()]
  def wonder_picker_lines(detection, nav), do: WonderPicker.lines(detection, nav)

  @spec interview_detection(map()) :: map() | nil
  def interview_detection(result) do
    case interview_state(result) do
      %{question: question} = interview when is_binary(question) ->
        if answered_current_question?(interview) do
          nil
        else
          question
          |> String.trim()
          |> question_detection(interview)
        end

      _other ->
        nil
    end
  end

  @spec interview_reasoning_lines(map(), integer() | nil) :: [String.t()]
  def interview_reasoning_lines(result, tick \\ nil) do
    case {completed_user_done?(result), interview_state(result)} do
      {true, _iv} ->
        []

      {false, %{} = iv} ->
        Status.reasoning_lines(iv, tick, paused?(result))

      {_done?, _none} ->
        []
    end
  end

  @spec mcp_activity_lines(map()) :: [String.t()]
  def mcp_activity_lines(result) do
    if completed_user_done?(result) do
      []
    else
      case interview_state(result) do
        %{mcp_activity: lines} -> Status.mcp_activity_lines(lines)
        _none -> []
      end
    end
  end

  @spec interview_block_lines(map(), map() | nil, integer()) ::
          {String.t(), [String.t() | {String.t(), atom()} | :rule], String.t()} | nil
  def interview_block_lines(result, nav, tick) do
    cond do
      detection = wonder_detection(result) ->
        wonder_picker_block(result, detection, nav, tick)

      completed_user_done?(result) ->
        nil

      interview_state(result) ->
        lines = interview_state_rows(result, tick)
        paused? = paused?(result)
        decision? = interview_decision_pending?(result)

        {Hints.marker(paused?), lines,
         if(decision?,
           do: Hints.wonder_pick_hint(paused?, 1),
           else: Hints.wonder_hint(paused?, not is_nil(wonder_detection(result)))
         )}

      session = interview_session(result) ->
        label = Map.get(session, :label, "ooo interview")
        paused? = paused?(result)
        spinner = if paused?, do: [], else: [{working_line(tick, nil, nil), :dim}]
        {Hints.marker(paused?), [label | spinner], Hints.session_hint(paused?)}

      true ->
        nil
    end
  rescue
    _exception -> emergency_interview_block(result, tick)
  end

  defp emergency_interview_block(result, tick) do
    case interview_state(result) do
      %{} = interview ->
        paused? = paused?(result)
        question = interview |> Map.get(:question) |> plain_line()

        lines =
          if question == "",
            do: [{"Interview checkpoint is waiting for your answer", :warn}],
            else: [{question, :warn}]

        {Hints.marker(paused?),
         lines ++ Enum.map(interview_working_lines(result, tick), &{&1, :dim}),
         Hints.wonder_hint(paused?, false)}

      _none ->
        nil
    end
  rescue
    _exception -> nil
  end

  defp wonder_picker_block(result, detection, nav, tick) do
    case wonder_picker_lines(detection, nav) do
      [] ->
        fallback_interview_block(result, tick)

      picker ->
        paused? = paused?(result)

        {Hints.marker(paused?), picker,
         Hints.wonder_pick_hint(paused?, question_count(detection))}
    end
  end

  defp fallback_interview_block(result, tick) do
    case interview_state(result) do
      nil ->
        nil

      _interview ->
        paused? = paused?(result)
        decision? = interview_decision_pending?(result)

        {Hints.marker(paused?), interview_state_rows(result, tick),
         if(decision?,
           do: Hints.wonder_pick_hint(paused?, 1),
           else: Hints.wonder_hint(paused?, false)
         )}
    end
  end

  defp interview_state_rows(result, tick) do
    case answer_transition_rows(result, tick) do
      [] ->
        case interview_option_rows(result) do
          [] ->
            result
            |> interview_ledger_or_dialogue_rows(false)
            |> maybe_prepend_current_question(result)
            |> Kernel.++(interview_error_rows(result))
            |> Kernel.++(interview_status_rows(result, tick))

          option_rows ->
            result
            |> interview_ledger_rows(include_current?: false)
            |> Kernel.++(option_rows)
            |> Kernel.++(interview_status_rows(result, tick))
        end

      rows ->
        rows
    end
  end

  defp interview_option_rows(result) do
    case interview_state(result) do
      %{question: question} = interview when is_binary(question) ->
        if answered_current_question?(interview) do
          []
        else
          question
          |> String.trim()
          |> question_picker_lines(interview)
        end

      _other ->
        []
    end
  end

  defp interview_ledger_or_dialogue_rows(result, drop_trailing_mcp?) do
    case interview_ledger_rows(result) do
      [] -> dialogue_rows(result, drop_trailing_mcp?)
      rows -> rows
    end
  end

  defp interview_ledger_rows(result, opts \\ []) do
    result
    |> interview_state()
    |> QuestionLedger.rows(opts)
  end

  defp interview_decision_pending?(result) do
    case interview_option_rows(result) do
      [] -> false
      _rows -> true
    end
  end

  defp question_picker_lines("", _interview), do: []

  defp question_picker_lines(question, interview) do
    question = plain_line(question)
    question |> question_detection(interview) |> wonder_picker_lines(nil)
  end

  defp question_detection("", _interview), do: nil

  defp question_detection(question, interview) do
    question = plain_line(question)
    options = question_options(interview)

    %{
      request: %{
        questions: [
          %{
            id: "interview",
            header: "Interview",
            question: question,
            options: options
          }
        ]
      }
    }
  end

  defp question_options(%{question_options: [_first | _rest] = options}), do: options
  defp question_options(_interview), do: []

  defp answered_current_question?(%{answered: text}) when is_binary(text) do
    String.trim(text) != ""
  end

  defp answered_current_question?(%{dialogue: dialogue}) when is_list(dialogue) do
    last_turn_answered?(dialogue) and Enum.any?(Enum.drop(dialogue, -1), &(turn_role(&1) == :mcp))
  end

  defp answered_current_question?(_interview), do: false

  defp last_turn_answered?(dialogue) do
    turn = List.first(dialogue)
    turn_role(turn) == :user and String.trim(turn_text(turn)) != ""
  end

  defp turn_role(%{role: role}) when is_atom(role), do: role
  defp turn_role(%{role: role}) when is_binary(role), do: role_atom(role)
  defp turn_role(%{"role" => role}) when is_atom(role), do: role
  defp turn_role(%{"role" => role}) when is_binary(role), do: role_atom(role)
  defp turn_role(_turn), do: nil

  defp role_atom("mcp"), do: :mcp
  defp role_atom("user"), do: :user
  defp role_atom("main"), do: :main
  defp role_atom(_role), do: nil

  defp turn_text(%{text: text}) when is_binary(text), do: text
  defp turn_text(%{"text" => text}) when is_binary(text), do: text
  defp turn_text(_turn), do: ""

  defp active_question_waiting?(%{} = interview) do
    active_question?(interview) and not answered_current_question?(interview)
  end

  defp active_question_waiting?(_interview), do: false

  defp active_question?(%{question: question}) when is_binary(question),
    do: String.trim(question) != ""

  defp active_question?(%{question_options: [_first | _rest]}), do: true

  defp active_question?(%{mcp_reasoning: lines}) when is_list(lines) do
    Enum.any?(lines, fn line ->
      line = line |> plain_line() |> String.downcase()

      String.contains?(line, "pending question") or
        String.contains?(line, "source: session_state")
    end)
  end

  defp active_question?(%{dialogue: [%{role: :mcp, text: text} | _rest]}) when is_binary(text),
    do: String.trim(text) != ""

  defp active_question?(_interview), do: false

  defp stale_question_answered?(%{} = interview), do: answered_current_question?(interview)

  defp stale_question_answered?(_interview), do: false

  defp maybe_prepend_current_question(rows, result) do
    case interview_state(result) do
      %{} = interview ->
        if stale_question_answered?(interview),
          do: rows,
          else: prepend_current_question(rows, result)

      _other ->
        rows
    end
  end

  defp prepend_current_question(rows, result) do
    question =
      result
      |> interview_state()
      |> case do
        %{} = iv -> Map.get(iv, :question)
        _none -> nil
      end
      |> plain_line()

    if question == "" or Enum.any?(rows, &line_contains?(&1, question)) do
      rows
    else
      [{question, :warn} | rows]
    end
  end

  defp line_contains?({text, _style}, needle) when is_binary(text),
    do: String.contains?(text, needle)

  defp line_contains?(text, needle) when is_binary(text), do: String.contains?(text, needle)
  defp line_contains?(_line, _needle), do: false

  defp waiting_for_user?(%{status: status}) when is_binary(status),
    do: String.downcase(status) == "waiting for your answer"

  defp waiting_for_user?(_interview), do: false

  defp completed_without_visible_answer?(%{complete: complete}, trace) when not is_nil(complete),
    do: not seed_ready_answer_trace?(complete, trace)

  defp completed_without_visible_answer?(_interview, _trace), do: false

  defp seed_ready_answer_trace?(complete, trace) when complete in [:seed_ready, "seed_ready"] do
    trace
    |> Text.flatten_line()
    |> String.upcase()
    |> String.starts_with?("ANSWER")
  end

  defp seed_ready_answer_trace?(_complete, _trace), do: false

  defp interview_error?(%{status: status}) when is_binary(status),
    do: interview_error_status?(status)

  defp interview_error?(_interview), do: false

  defp interview_error_rows(result) do
    case interview_state(result) do
      %{status: status} = interview when is_binary(status) ->
        if interview_error_status?(status) do
          rows = [{"Question " <> plain_line(status), :warn}]

          case Map.get(interview, :session_id) do
            session_id when is_binary(session_id) and session_id != "" ->
              rows ++ [{"Session  " <> session_id <> " resume available", :dim}]

            _none ->
              rows
          end
        else
          []
        end

      _other ->
        []
    end
  end

  defp interview_error_status?(status) when is_binary(status) do
    status = String.downcase(status)

    String.contains?(status, "unavailable") or
      String.contains?(status, "failed") or
      String.contains?(status, "did not open")
  end

  @spec default_nav(map(), map() | nil) :: map()
  def default_nav(detection, current_nav), do: WonderPicker.default_nav(detection, current_nav)

  @spec question_count(map()) :: non_neg_integer()
  def question_count(detection), do: WonderPicker.question_count(detection)

  @spec wonder_questions(map()) :: [map()]
  def wonder_questions(detection), do: WonderPicker.questions(detection)

  @spec nav_qidx(map() | nil) :: integer()
  def nav_qidx(nav), do: WonderPicker.nav_qidx(nav)

  @spec nav_cursor(map() | nil, integer()) :: integer()
  def nav_cursor(nav, qi), do: WonderPicker.nav_cursor(nav, qi)

  @spec nav_pick(map() | nil, integer()) :: integer()
  def nav_pick(nav, qi), do: WonderPicker.nav_pick(nav, qi)

  @spec nav_multi_pick(map() | nil, integer()) :: MapSet.t()
  def nav_multi_pick(nav, qi), do: WonderPicker.nav_multi_pick(nav, qi)

  @spec multi_select?(map()) :: boolean()
  def multi_select?(question), do: WonderPicker.multi_select?(question)

  @spec md_text(term()) :: String.t()
  def md_text(text), do: Text.md_text(text)

  @spec flatten_line(term()) :: String.t()
  def flatten_line(text), do: Text.flatten_line(text)

  @spec working_line(integer(), term()) :: String.t()
  def working_line(tick, trace) do
    working_line(tick, trace, nil)
  end

  @spec working_line(integer(), term(), non_neg_integer() | nil) :: String.t()
  def working_line(tick, trace, elapsed_seconds) do
    Status.working_line(tick, trace, elapsed_seconds)
  end

  @spec spin(integer() | term()) :: String.t()
  def spin(tick), do: Status.spin(tick)

  defp interview_status_rows(result, tick) do
    status = interview_working_lines(result, tick) ++ delayed_waiting_action_rows(result)

    cond do
      status == [] ->
        []

      dialogue_rows(result, false) == [] ->
        Enum.map(status, &{&1, :dim})

      true ->
        [:rule | Enum.map(status, &{&1, :dim})]
    end
  end

  @spec plain_line(term()) :: String.t()
  def plain_line(text), do: Text.plain_line(text)

  defp interview_state(result) do
    InterviewLiveState.interview(result)
  end

  defp waiting_elapsed_seconds(%{waiting_started_monotonic_ms: started})
       when is_integer(started) do
    div(max(System.monotonic_time(:millisecond) - started, 0), 1000)
  end

  defp waiting_elapsed_seconds(_interview), do: nil

  defp delayed_waiting_action_rows(result) do
    case interview_state(result) do
      %{waiting: true} = interview ->
        elapsed = waiting_elapsed_seconds(interview)

        if is_integer(elapsed) and elapsed >= 2 and not active_question?(interview) do
          delayed_waiting_action_text(elapsed)
        else
          []
        end

      _other ->
        []
    end
  end

  defp answer_transition_rows(result, tick) do
    case interview_state(result) do
      %{waiting: true, last_answer: answer} = interview when is_binary(answer) ->
        answer = plain_line(answer)

        if answer == "" do
          []
        else
          rows =
            (QuestionLedger.rows(interview,
               expand_selected?: expand_transition_selection?(interview)
             ) ++
               [
                 {"Round accepted", :strong},
                 transition_question_row(interview),
                 {"Answer    " <> answer, :strong},
                 transition_phase_row(interview),
                 :rule,
                 {transition_working_line(tick, interview), :dim}
               ])
            |> Enum.reject(&is_nil/1)

          rows ++ Enum.map(delayed_waiting_action_rows(result), &{&1, :dim})
        end

      _other ->
        []
    end
  end

  defp transition_question_row(%{last_answered_question: question}) when is_binary(question) do
    question = plain_line(question)
    if question == "", do: nil, else: {"Question  " <> question, :warn}
  end

  defp transition_question_row(_interview), do: nil

  defp expand_transition_selection?(interview) do
    explicit_selected =
      Map.get(interview, :selected_question_block_id) ||
        Map.get(interview, "selected_question_block_id")

    is_binary(explicit_selected) and String.trim(explicit_selected) != ""
  end

  defp transition_phase_row(%{status: status}) when is_binary(status) do
    {"Next      " <> transition_phase_label(status), :dim}
  end

  defp transition_phase_row(_interview), do: nil

  defp transition_working_line(tick, interview) do
    elapsed = waiting_elapsed_seconds(interview)
    phase = transition_working_phase(interview)

    label =
      cond do
        is_integer(elapsed) and elapsed >= 15 ->
          "still #{phase} (~#{elapsed}s) - working, not stuck; Esc adds context"

        is_integer(elapsed) and elapsed >= 6 ->
          "#{phase} (~#{elapsed}s) - no input needed; Esc pauses"

        true ->
          phase <> " - choices will appear here"
      end

    spin(tick) <> " " <> label
  end

  defp transition_phase_label(status) do
    case String.downcase(status) do
      "opening interview session to send answer" ->
        "opening interview session"

      "answer sent - generating next question" ->
        "answer sent; generating choices"

      "preparing next interview question" ->
        "answer sent; generating choices"

      "answer accepted - preparing next question" ->
        "answer accepted; waiting for session"

      other ->
        other
    end
  end

  defp transition_working_phase(%{status: status}) when is_binary(status) do
    case String.downcase(status) do
      "opening interview session to send answer" -> "opening the interview session"
      "answer accepted - preparing next question" -> "opening the interview session"
      "answer sent - generating next question" -> "building next answer choices"
      "preparing next interview question" -> "building next answer choices"
      _other -> "building the next question"
    end
  end

  defp transition_working_phase(_interview), do: "building the next question"

  defp delayed_waiting_action_text(elapsed) when elapsed >= 15 do
    [
      "No input needed; choices will appear automatically",
      "Esc pauses so you can add context",
      "/cancel stops; submit the same command to retry"
    ]
  end

  defp delayed_waiting_action_text(_elapsed) do
    [
      "No input needed; choices will appear automatically",
      "Esc pauses so you can add context",
      "/cancel stops this interview"
    ]
  end

  defp wonder_detection(result) do
    InterviewLiveState.wonder_tool(result)
  end

  defp interview_session(result) do
    InterviewLiveState.interview_session(result)
  end

  defp paused?(result) do
    InterviewLiveState.paused?(result)
  end

  defp completed_user_done?(result) do
    case interview_state(result) do
      %{complete: :user_done} -> true
      %{complete: "user_done"} -> true
      _other -> false
    end
  end
end
