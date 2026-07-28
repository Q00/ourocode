defmodule Ourocode.Terminal.TuiChat do
  @moduledoc false

  alias Ourocode.Model
  alias Ourocode.Model.Conversation

  alias Ourocode.Terminal.{
    ConversationStore,
    InterviewHandoff,
    InterviewPanel,
    TuiInteraction,
    TuiState
  }

  @spec chat(
          String.t(),
          map(),
          pid(),
          pid(),
          pos_integer(),
          pos_integer(),
          function(),
          function()
        ) ::
          :ok
  def chat(prompt, result, output, state, cols, rows, active_model, redraw)
      when is_function(active_model, 1) and is_function(redraw, 6) do
    model = active_model.(state)

    cond do
      model == nil ->
        log(output, "you> #{prompt}")
        log(output, "No model available. /model to pick one, /login for ChatGPT.")
        redraw.(result, output, state, "", cols, rows)

      Model.needs_auth?(model) ->
        log(output, "you> #{prompt}")
        log(output, "#{model.label} needs sign-in. /login for ChatGPT, or /model.")
        redraw.(result, output, state, "", cols, rows)

      true ->
        stream_chat(model, prompt, result, output, state, cols, rows, redraw)
    end
  end

  @tick_ms 120

  defp stream_chat(model, prompt, result, output, state, cols, rows, redraw) do
    log(output, "you> #{prompt}")
    IO.write(output, "ourocode> ")
    TuiState.set_streaming(state, true)
    redraw.(result, output, state, "", cols, rows)

    model_prompt = maybe_paused_interview_prompt(result, prompt)
    conversation = conversation(result, state)
    stream_opts = [session_id: session_id(result), history: conversation]
    stream_opts = put_configured_model(stream_opts, model, state)
    started = System.monotonic_time(:millisecond)

    case run_turn(
           model,
           model_prompt,
           stream_opts,
           started,
           result,
           output,
           state,
           cols,
           rows,
           redraw
         ) do
      {:ok, full} ->
        # Remember the exchange as the user typed it (not the paused-interview
        # wrapper) so follow-up turns read as a clean dialogue.
        conversation = Conversation.add_turn(conversation, prompt, full)
        TuiState.put_conversation(state, conversation)
        ConversationStore.save(ConversationStore.project_dir(result), conversation)
        IO.write(output, "\n")
        maybe_handoff_paused_interview_answer(result, output, full)

      :cancelled ->
        log(output, "\n-- turn cancelled")

      {:error, :not_signed_in} ->
        log(output, "\nNot connected. /login for ChatGPT.")

      {:error, reason} ->
        log(output, "\n#{model.label} error: #{inspect(reason)}")
    end

    TuiState.set_streaming(state, false)
    redraw.(result, output, state, "", cols, rows)
  end

  # The turn runs in a monitored process so the UI stays alive while the
  # backend is silent: ticks keep the "thinking" indicator animating even
  # when no chunk has arrived yet, chunks render as they stream in, a bare
  # Esc or Ctrl+C cancels the turn, and keystrokes typed during the turn are
  # re-buffered for the input loop instead of being dropped.
  defp run_turn(
         model,
         model_prompt,
         stream_opts,
         started,
         result,
         output,
         state,
         cols,
         rows,
         redraw
       ) do
    caller = self()

    {pid, ref} =
      spawn_monitor(fn ->
        outcome =
          Model.stream(model, model_prompt, stream_opts, fn chunk ->
            send(caller, {:chat_chunk, chunk})
          end)

        send(caller, {:chat_outcome, self(), outcome})
      end)

    await_turn(pid, ref, started, TuiState.port(state), result, output, state, cols, rows, redraw)
  end

  defp await_turn(pid, ref, started, port, result, output, state, cols, rows, redraw) do
    receive do
      {:chat_chunk, chunk} ->
        # Stamp time-to-first-token once, for the footer latency readout.
        if TuiState.streaming?(state) and started != nil do
          TuiState.put_last_turn_ms(state, System.monotonic_time(:millisecond) - started)
        end

        IO.write(output, chunk)
        redraw.(result, output, state, "", cols, rows)
        await_turn(pid, ref, nil, port, result, output, state, cols, rows, redraw)

      {:chat_outcome, ^pid, outcome} ->
        Process.demonitor(ref, [:flush])
        outcome

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:chat_crashed, reason}}

      {^port, {:data, data}} ->
        if cancel_request?(data) do
          stop_turn(pid, ref)
          :cancelled
        else
          rebuffer_input(state, data)
          await_turn(pid, ref, started, port, result, output, state, cols, rows, redraw)
        end

      {^port, {:exit_status, _status}} ->
        stop_turn(pid, ref)
        :cancelled
    after
      @tick_ms ->
        redraw.(result, output, state, "", cols, rows)
        await_turn(pid, ref, started, port, result, output, state, cols, rows, redraw)
    end
  end

  defp stop_turn(pid, ref) do
    Process.exit(pid, :kill)
    Process.demonitor(ref, [:flush])
    drain_chat_chunks()
  end

  defp drain_chat_chunks do
    receive do
      {:chat_chunk, _chunk} -> drain_chat_chunks()
    after
      0 -> :ok
    end
  end

  defp put_configured_model(opts, %Model{id: provider_id}, state) when is_atom(provider_id) do
    case TuiState.provider_model_slug(state, provider_id) do
      slug when is_binary(slug) and slug != "" ->
        opts
        |> Keyword.put(:model, slug)
        |> Keyword.put(:model_source, :session)

      _none ->
        opts
    end
  end

  defp put_configured_model(opts, _model, _state), do: opts

  # A bare Esc or a Ctrl+C cancels the turn; longer escape sequences (arrow
  # keys and friends) are ordinary input and must not abort the stream.
  defp cancel_request?(data), do: data == <<27>> or String.contains?(data, <<3>>)

  defp rebuffer_input(state, data) do
    TuiState.put_inbuf(state, TuiState.take_inbuf(state) <> data)
  end

  defp maybe_paused_interview_prompt(result, prompt) do
    if TuiInteraction.paused?(result) and
         (TuiInteraction.interview_active?(result) or TuiInteraction.wonder_active?(result)) do
      InterviewHandoff.prompt(paused_interview_question(result), prompt)
    else
      prompt
    end
  end

  defp paused_interview_question(result) do
    cond do
      detection = TuiInteraction.wonder_detection(result) ->
        detection
        |> InterviewPanel.wonder_questions()
        |> List.first()
        |> case do
          %{} = question -> InterviewPanel.md_text(Map.get(question, :question, ""))
          _none -> "unknown"
        end

      interview = TuiInteraction.interview_state(result) ->
        InterviewPanel.md_text(Map.get(interview, :question, "unknown"))

      true ->
        "unknown"
    end
  end

  defp maybe_handoff_paused_interview_answer(result, output, full) do
    with true <- TuiInteraction.paused?(result),
         true <- TuiInteraction.interview_active?(result) or TuiInteraction.wonder_active?(result),
         answer when is_binary(answer) <- InterviewHandoff.extract_answer(full),
         send when is_function(send, 1) <- Map.get(result, :interview_answer),
         {:ok, _text} <- send.(answer) do
      log(output, "-- interview answered from main session")
    else
      _other -> :ok
    end
  end

  # nil state means "not loaded yet": the first chat of a run restores the
  # project's persisted dialogue, so the conversation survives restarts.
  defp conversation(result, state) do
    case TuiState.conversation(state) do
      %Conversation{} = conversation ->
        conversation

      nil ->
        conversation = ConversationStore.load(ConversationStore.project_dir(result))
        TuiState.put_conversation(state, conversation)
        conversation
    end
  end

  defp session_id(result) do
    get_in(result, [:runtime, :session_id]) || get_in(result, [:context, :runtime_session_id]) ||
      "ourocode-main"
  end

  defp log(output, text), do: IO.puts(output, String.replace_invalid(text, ""))
end
