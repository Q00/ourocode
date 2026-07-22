defmodule Ourocode.Terminal.TuiAnswerSubmission do
  @moduledoc false

  alias Ourocode.Terminal.{TuiState, WonderNavigation}

  @spec submit_free_text(String.t(), map(), pid(), pid(), map()) :: :ok
  def submit_free_text(answer, result, output, state, context) when is_binary(answer) do
    answer = String.trim(answer)

    cond do
      answer == "" ->
        log(output, "usage: /answer <interview answer>")

      Map.get(context, :interview_active?) ->
        submit_interview_answer(answer, result, output)

      Map.get(context, :wonder_active?) ->
        submit_wonder_free_text(answer, result, output, state, context)

      true ->
        log(output, "No active interview answer target.")
    end
  end

  @spec submit_enter_answer(String.t(), map(), pid(), pid(), map()) :: :handled | :not_handled
  def submit_enter_answer(answer, result, output, state, context) when is_binary(answer) do
    answer = String.trim(answer)

    cond do
      answer != "" and Map.get(context, :wonder_active?) and cancel_answer?(answer) ->
        TuiState.push_notification(state, "step submitting - cancelling checkpoint")
        submit_cancel(answer, result, output, state)
        :handled

      answer != "" and command_like_answer?(answer) and active_interview_context?(context) ->
        TuiState.push_notification(
          state,
          "command held - pause or cancel before starting new work"
        )

        log(output, "Command held. Press Esc to discuss, or /cancel to stop this interview.")
        :handled

      answer != "" and Map.get(context, :wonder_active?) ->
        TuiState.push_notification(state, "step submitting - sending free answer")
        submit_wonder_free_text(answer, result, output, state, context)
        :handled

      answer != "" and Map.get(context, :interview_active?) ->
        TuiState.push_notification(state, "step submitting - sending interview answer")
        submit_interview_answer(answer, result, output, state)
        :handled

      answer != "" ->
        :handled

      true ->
        :not_handled
    end
  end

  defp active_interview_context?(context) do
    Map.get(context, :wonder_active?) or Map.get(context, :interview_active?)
  end

  defp command_like_answer?(answer) when is_binary(answer) do
    answer
    |> String.trim_leading()
    |> String.downcase()
    |> then(fn text ->
      text == "ooo" or String.starts_with?(text, "ooo ") or
        text == "ouroboros" or String.starts_with?(text, "ouroboros ")
    end)
  end

  defp submit_cancel(answer, result, output, state) do
    cancel = Map.get(result, :wonder_cancel)

    case cancel && cancel.(answer) do
      {:ok, _cancelled} ->
        TuiState.push_notification(state, "step accepted - checkpoint cancelled")
        log(output, "you> #{answer}")

      _other ->
        :ok
    end
  end

  defp submit_interview_answer(answer, result, output, state \\ nil) do
    send = Map.get(result, :interview_answer)

    case send && send.(answer) do
      {:ok, _text} ->
        if is_pid(state),
          do: TuiState.push_notification(state, "step accepted - answer captured")

        log(output, "you> #{answer}")

      _other ->
        log(output, "No active interview answer target.")
    end
  end

  defp submit_wonder_free_text(answer, result, output, state, context) do
    submit = Map.get(result, :wonder_answer)
    detection = Map.fetch!(context, :wonder_detection)

    payload =
      WonderNavigation.free_text_payload(
        detection,
        TuiState.wonder_nav(state),
        answer
      )

    case submit && submit.(payload) do
      {:ok, decision} ->
        TuiState.push_notification(state, "step accepted - answer captured")
        log(output, "you> #{Map.get(decision, :selected_label, answer)}")

      _other ->
        log(output, "No active wonder answer target.")
    end
  end

  defp cancel_answer?(answer) when is_binary(answer) do
    answer
    |> String.downcase()
    |> String.trim()
    |> Kernel.in(["cancel", "decline", "/cancel"])
  end

  defp log(output, text), do: IO.puts(output, String.replace_invalid(text, ""))
end
