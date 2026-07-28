defmodule Ourocode.Terminal.TuiInteraction do
  @moduledoc false

  alias Ourocode.Terminal.{
    InterviewLiveState,
    InterviewPanel,
    InterviewPanel.QuestionLedger,
    TuiAnswerSubmission,
    TuiState,
    WonderNavigation
  }

  @spec handle_event(map(), map(), pid(), pid()) :: :ok
  def handle_event(%{key: :enter}, result, output, state) do
    if String.trim(TuiState.buffer(state)) == "" and
         is_binary(TuiState.mcp_ledger_selected_id(state)) do
      TuiState.push_notification(state, "tool call opened", 900)
      :ok
    else
      submit_enter(result, output, state)
    end
  end

  def handle_event(%{key: :escape}, result, output, state) do
    case Map.get(result, :wonder_pause) do
      pause when is_function(pause, 0) ->
        pause.()
        TuiState.put_force_interview_paused(state, true)
        TuiState.push_notification(state, "paused - /answer resumes, /cancel stops", 2_500)
        log(output, "-- interview paused (type normally to discuss; /answer <text> resumes)")

      _none ->
        :ok
    end
  end

  def handle_event(_event, _result, _output, _state), do: :ok

  defp submit_enter(result, output, state) do
    answer = String.trim(TuiState.take_buffer(state))

    case TuiAnswerSubmission.submit_enter_answer(answer, result, output, state, context(result)) do
      :handled ->
        :ok

      :not_handled ->
        submit_selection(result, output, state)
    end
  end

  @spec submit_slash_answer(String.t(), map(), pid(), pid()) :: :ok
  def submit_slash_answer(answer, result, output, state) when is_binary(answer) do
    TuiState.put_force_interview_paused(state, false)
    TuiAnswerSubmission.submit_free_text(answer, result, output, state, context(result))
  end

  @spec submit_cancel(map(), pid(), pid()) :: :handled | :not_handled
  def submit_cancel(result, output, state) do
    cond do
      wonder_active?(result) ->
        TuiState.push_notification(state, "step submitting - cancelling checkpoint")

        case Map.get(result, :wonder_cancel) do
          cancel when is_function(cancel, 1) ->
            case cancel.("cancel") do
              {:ok, _cancelled} ->
                TuiState.put_force_interview_paused(state, false)
                TuiState.put_wonder_nav(state, nil)
                stop_interview_after_cancel(result, state)
                show_cancelled_workspace(state)
                clear_captured_activity(output)
                :handled

              _other ->
                :not_handled
            end

          _none ->
            stop_plain_interview(result, output, state)
        end

      interview_active?(result) ->
        stop_plain_interview(result, output, state)

      true ->
        :not_handled
    end
  end

  @spec nav_event?(map(), String.t(), map(), pid()) :: boolean()
  def nav_event?(event, buffer, result, state) do
    cond do
      ledger_mouse_event?(event) and ledger_mouse_routable?(event, state) ->
        true

      true ->
        nav_selection_event?(event, buffer, result, state)
    end
  end

  defp nav_selection_event?(event, buffer, result, state) do
    case selection_detection(result) do
      nil ->
        buffer == "" and ledger_nav_event?(event, result, state)

      detection ->
        WonderNavigation.nav_event?(event, buffer, detection, TuiState.wonder_nav(state))
    end
  end

  @spec handle_nav(map(), map(), pid()) :: :ok
  def handle_nav(event, result, state) do
    detection = selection_detection(result)

    cond do
      ledger_mouse_event?(event) ->
        handle_ledger_mouse(event, state)

      detection ->
        case nav_after(detection, TuiState.wonder_nav(state), event) do
          nil -> :ok
          nav -> TuiState.put_wonder_nav(state, nav)
        end

      true ->
        handle_ledger_nav(event, result, state)
    end

    :ok
  end

  @doc false
  def nav_after(detection, nav, event), do: WonderNavigation.after_event(detection, nav, event)

  @spec free_text_payload(map(), pid(), String.t()) :: map()
  def free_text_payload(result, state, answer) do
    WonderNavigation.free_text_payload(
      selection_detection(result),
      TuiState.wonder_nav(state),
      answer
    )
  end

  defp context(result) do
    detection = wonder_detection(result)

    %{
      wonder_active?: detection != nil,
      wonder_detection: detection,
      interview_active?: interview_active?(result)
    }
  end

  @spec capturing?(map()) :: boolean()
  def capturing?(result) do
    (wonder_active?(result) or interview_active?(result)) and not paused?(result)
  end

  @spec capturing?(map(), pid()) :: boolean()
  def capturing?(result, state) when is_pid(state) do
    capturing?(result) and not TuiState.interview_cancelled?(state)
  end

  @spec wonder_active?(map()) :: boolean()
  def wonder_active?(result), do: wonder_detection(result) != nil

  @spec selection_active?(map()) :: boolean()
  def selection_active?(result),
    do: selection_detection(result) != nil or ledger_blocks(result) != []

  @spec mcp_ledger_active?(pid()) :: boolean()
  def mcp_ledger_active?(state) when is_pid(state),
    do:
      map_size(TuiState.mcp_ledger_hit_map(state)) > 0 or
        is_binary(TuiState.mcp_ledger_selected_id(state))

  @spec interview_active?(map()) :: boolean()
  def interview_active?(result) do
    case interview_state(result) do
      %{} = interview -> Map.get(interview, :complete) in [nil, false]
      _none -> false
    end
  end

  @spec paused?(map()) :: boolean()
  def paused?(result), do: InterviewLiveState.paused?(result)

  @spec wonder_detection(map()) :: map() | nil
  def wonder_detection(result), do: InterviewLiveState.wonder_tool(result)

  @spec selection_detection(map()) :: map() | nil
  def selection_detection(result) do
    wonder_detection(result) || InterviewPanel.interview_detection(result)
  end

  @spec interview_state(map()) :: map() | nil
  def interview_state(result), do: InterviewLiveState.interview(result)

  defp submit_selection(result, output, state) do
    cond do
      any_free_answer_selected?(result, state) ->
        :ok

      needs_review?(result, state) ->
        TuiState.put_wonder_nav(state, Map.put(TuiState.wonder_nav(state), :review?, true))
        TuiState.push_notification(state, "step review - confirm answers before submit")

      true ->
        TuiState.push_notification(state, "step submitting - sending selected answers")

        if wonder_active?(result) do
          submit_wonder_selection(result, output, state)
        else
          submit_interview_selection(result, output, state)
        end
    end
  end

  defp submit_wonder_selection(result, output, state) do
    submit = Map.get(result, :wonder_answer)
    selections = selections(result, state)

    case submit && submit.(selections) do
      {:ok, decision} ->
        selected = Map.get(decision, :selected_label, "")
        TuiState.push_notification(state, accepted_notification(selected))
        log(output, "you> #{selected}")

      _other ->
        :ok
    end
  end

  defp submit_interview_selection(result, output, state) do
    case selected_interview_label(result, state) do
      label when is_binary(label) and label != "" ->
        send = Map.get(result, :interview_answer)

        case send && send.(label) do
          {:ok, _text} ->
            TuiState.push_notification(state, accepted_notification(label))
            log(output, "you> #{label}")

          _other ->
            log(output, "No active interview answer target.")
        end

      _free_text ->
        :ok
    end
  end

  defp selected_interview_label(result, state) do
    detection = selection_detection(result)
    nav = TuiState.wonder_nav(state)

    with %{} = question <- WonderNavigation.active_question(detection, nav),
         [selected | _rest] <- WonderNavigation.selections(detection, nav),
         selected when is_integer(selected) <- selected,
         options when is_list(options) <-
           Map.get(question, :options, Map.get(question, "options", [])),
         %{} = option <- Enum.at(options, selected - 1) do
      Map.get(option, :label, Map.get(option, "label", ""))
    else
      _other -> nil
    end
  end

  defp ledger_nav_event?(%{key: key}, result, state) when key in [:up, :down],
    do: ledger_blocks(result) != [] or mcp_ledger_ids(state) != []

  defp ledger_nav_event?(%{key: :char, char: char}, result, state)
       when char in ["j", "k", "+", "-"],
       do: ledger_blocks(result) != [] or mcp_ledger_ids(state) != []

  defp ledger_nav_event?(%{key: :char, char: char}, result, state) when is_binary(char),
    do: char =~ ~r/^[1-9]$/ and (ledger_blocks(result) != [] or mcp_ledger_ids(state) != [])

  defp ledger_nav_event?(_event, _result, _state), do: false

  defp ledger_mouse_event?(%{type: :mouse, key: key}) when key in [:mouse_move, :mouse_down],
    do: true

  defp ledger_mouse_event?(_event), do: false

  defp ledger_mouse_routable?(%{key: :mouse_down, x: x, y: y}, state),
    do: is_binary(hit_ledger_id(state, x, y)) or is_binary(hit_mcp_ledger_id(state, x, y))

  defp ledger_mouse_routable?(%{key: :mouse_move, x: x, y: y}, state) do
    is_binary(hit_ledger_id(state, x, y)) or
      is_binary(hit_mcp_ledger_id(state, x, y)) or
      is_binary(TuiState.interview_ledger_hover_id(state)) or
      is_binary(TuiState.mcp_ledger_hover_id(state))
  end

  defp ledger_mouse_routable?(_event, _state), do: false

  defp handle_ledger_mouse(%{key: :mouse_move, x: x, y: y}, state) do
    TuiState.put_interview_ledger_hover_id(state, hit_ledger_id(state, x, y))
    TuiState.put_mcp_ledger_hover_id(state, hit_mcp_ledger_id(state, x, y))
  end

  defp handle_ledger_mouse(%{key: :mouse_down, x: x, y: y}, state) do
    case {hit_ledger_id(state, x, y), hit_mcp_ledger_id(state, x, y)} do
      {id, _mcp_id} when is_binary(id) ->
        TuiState.put_mcp_ledger_hover_id(state, nil)
        TuiState.put_interview_ledger_hover_id(state, id)
        TuiState.put_interview_ledger_selected_id(state, id)
        TuiState.push_notification(state, "question opened", 900)

      {_interview_id, id} when is_binary(id) ->
        TuiState.put_interview_ledger_hover_id(state, nil)
        TuiState.put_mcp_ledger_hover_id(state, id)
        TuiState.put_mcp_ledger_selected_id(state, id)
        TuiState.push_notification(state, "tool call opened", 900)

      _none ->
        TuiState.put_interview_ledger_hover_id(state, nil)
        TuiState.put_mcp_ledger_hover_id(state, nil)
    end
  end

  defp handle_ledger_mouse(_event, _state), do: :ok

  defp hit_ledger_id(state, x, y) when is_integer(x) and is_integer(y) do
    case Map.get(TuiState.interview_ledger_hit_map(state), y) do
      %{id: id, x1: x1, x2: x2} when x >= x1 and x <= x2 -> id
      _none -> nil
    end
  end

  defp hit_ledger_id(_state, _x, _y), do: nil

  defp hit_mcp_ledger_id(state, x, y) when is_integer(x) and is_integer(y) do
    case Map.get(TuiState.mcp_ledger_hit_map(state), y) do
      %{id: id, x1: x1, x2: x2} when x >= x1 and x <= x2 -> id
      _none -> nil
    end
  end

  defp hit_mcp_ledger_id(_state, _x, _y), do: nil

  defp handle_ledger_nav(event, result, state) do
    blocks = ledger_blocks(result)
    mcp_ids = mcp_ledger_ids(state)

    cond do
      mcp_ids != [] and (blocks == [] or is_binary(TuiState.mcp_ledger_selected_id(state))) ->
        selected_id = TuiState.mcp_ledger_selected_id(state) || List.last(mcp_ids)
        current_index = Enum.find_index(mcp_ids, &(&1 == selected_id)) || length(mcp_ids) - 1
        next_index = ledger_next_index(event, current_index, length(mcp_ids))
        selected = Enum.at(mcp_ids, next_index)

        TuiState.put_mcp_ledger_selected_id(state, selected)
        TuiState.put_mcp_ledger_hover_id(state, selected)
        TuiState.put_interview_ledger_hover_id(state, nil)
        TuiState.push_notification(state, "tool call #{next_index + 1} selected", 900)

      blocks != [] ->
        selected_id = TuiState.interview_ledger_selected_id(state) || selected_ledger_id(result)

        current_index =
          Enum.find_index(blocks, &(Map.get(&1, :id) == selected_id)) || length(blocks) - 1

        next_index = ledger_next_index(event, current_index, length(blocks))
        selected = blocks |> Enum.at(next_index) |> Map.get(:id)

        TuiState.put_interview_ledger_selected_id(state, selected)
        TuiState.push_notification(state, "question Q#{next_index + 1} selected", 900)
    end
  end

  defp mcp_ledger_ids(state) do
    state
    |> TuiState.mcp_ledger_hit_map()
    |> Enum.sort_by(fn {row, _hit} -> row end)
    |> Enum.map(fn {_row, %{id: id}} -> id end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp ledger_next_index(%{key: key}, index, count) when key in [:down],
    do: min(index + 1, count - 1)

  defp ledger_next_index(%{key: key}, index, _count) when key in [:up], do: max(index - 1, 0)
  defp ledger_next_index(%{key: :char, char: "j"}, index, count), do: min(index + 1, count - 1)
  defp ledger_next_index(%{key: :char, char: "+"}, index, count), do: min(index + 1, count - 1)
  defp ledger_next_index(%{key: :char, char: "k"}, index, _count), do: max(index - 1, 0)
  defp ledger_next_index(%{key: :char, char: "-"}, index, _count), do: max(index - 1, 0)

  defp ledger_next_index(%{key: :char, char: char}, _index, count) when is_binary(char) do
    case Integer.parse(char) do
      {number, ""} -> max(0, min(number - 1, count - 1))
      _other -> 0
    end
  end

  defp selected_ledger_id(result) do
    result
    |> interview_state()
    |> QuestionLedger.from_interview()
    |> Map.get(:selected_block_id)
  end

  defp ledger_blocks(result) do
    result
    |> interview_state()
    |> QuestionLedger.from_interview()
    |> Map.get(:blocks, [])
  end

  defp needs_review?(result, state) do
    detection = selection_detection(result)
    qcount = detection |> InterviewPanel.wonder_questions() |> length()
    nav = TuiState.wonder_nav(state)

    qcount > 1 and not Map.get(nav || %{}, :review?, false)
  end

  defp selections(result, state) do
    WonderNavigation.selections(selection_detection(result), TuiState.wonder_nav(state))
  end

  defp any_free_answer_selected?(result, state) do
    WonderNavigation.any_free_answer_selected?(
      selection_detection(result),
      TuiState.wonder_nav(state)
    )
  end

  defp accepted_notification(""), do: "accepted - answer captured"
  defp accepted_notification(label), do: "accepted - " <> label

  defp log(output, text), do: IO.puts(output, String.replace_invalid(text, ""))

  defp clear_captured_activity(output) do
    StringIO.flush(output)
    :ok
  rescue
    _exception -> :ok
  end

  defp stop_interview_after_cancel(result, state) do
    if interview_active?(result) do
      TuiState.push_notification(state, "cancelled - interview stopped")
    else
      TuiState.push_notification(state, "cancelled - checkpoint closed")
    end
  end

  defp stop_plain_interview(result, output, state) do
    case send_interview_cancel(result) do
      :ok ->
        TuiState.put_force_interview_paused(state, false)
        TuiState.push_notification(state, "cancelled - interview stopped")
        show_cancelled_workspace(state)
        clear_captured_activity(output)
        :handled

      :error ->
        :not_handled
    end
  end

  defp show_cancelled_workspace(state) do
    TuiState.put_scroll(state, 0)
    TuiState.put_interview_cancelled(state, true)

    TuiState.put_workspace(state, %{
      kind: "interview",
      title: "Interview Stopped",
      status: "cancelled",
      selected: "cancelled:interview",
      records: [
        %{
          id: "cancelled:interview",
          title: "Interview",
          state: "stopped",
          health: "clean"
        }
      ],
      detail: %{
        id: "cancelled:interview",
        title: "Interview stopped",
        state: "stopped",
        fields: %{
          step: "cancel acknowledged",
          current: "no active question is waiting",
          progress: "checkpoint closed and composer restored",
          controls: "type a new goal, /agents, or /verify",
          evidence: "stale interview activity cleared"
        },
        actions: [
          action("start", "Start PM", "ooo pm <goal>", "Enter"),
          action("agents", "View agents", "/agents", "a")
        ]
      },
      actions: [
        action("start", "Start PM", "ooo pm <goal>", "Enter"),
        action("agents", "View agents", "/agents", "a"),
        action("verify", "Run verifier", "/verify", "v")
      ],
      shortcuts: ["Up/Dn rows", "Enter action", "type to compose"],
      next:
        "Start another guided run with ooo pm <goal>, ooo interview <goal>, or ooo auto <goal>."
    })
  end

  defp action(id, label, command, shortcut) do
    %{id: id, label: label, command: command, shortcut: shortcut, enabled: true}
  end

  defp send_interview_cancel(result) do
    case Map.get(result, :interview_cancel) do
      cancel when is_function(cancel, 0) ->
        case cancel.() do
          {:ok, _text} -> :ok
          _other -> :error
        end

      _none ->
        send_interview_cancel_answer(result)
    end
  end

  defp send_interview_cancel_answer(result) do
    case Map.get(result, :interview_answer) do
      send_answer when is_function(send_answer, 1) ->
        case send_answer.("cancel") do
          {:ok, _text} -> :ok
          _other -> :error
        end

      _none ->
        :error
    end
  end
end
