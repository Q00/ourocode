defmodule Ourocode.Terminal.TuiSubmit do
  @moduledoc false

  alias Ourocode.Provider.Codex

  alias Ourocode.Terminal.{
    ConversationStore,
    TuiChat,
    TuiInteraction,
    TuiLogin,
    TuiState,
    WorkspaceModel
  }

  @spec handle(String.t(), map(), pid(), pid(), pos_integer(), pos_integer(), keyword()) ::
          :continue | :exit | {:submit, String.t()}
  def handle(line, result, output, state, cols, rows, callbacks \\ [])

  def handle("", _result, _output, _state, _cols, _rows, _callbacks), do: :continue

  def handle("/login", result, output, state, cols, rows, callbacks) do
    # Open the provider picker so the user chooses what to sign into; picking
    # a not-ready OAuth provider (Codex or Claude) starts its login.
    TuiState.put_mode(state, :model)
    TuiState.put_pidx(state, 0)
    redraw(callbacks).(result, output, state, "", cols, rows)
    :continue
  end

  def handle("/logout", result, output, state, cols, rows, callbacks) do
    Codex.clear()
    log(output, "Signed out of ChatGPT.")
    redraw(callbacks).(result, output, state, "", cols, rows)
    :continue
  end

  def handle("/clear", result, output, state, cols, rows, callbacks) do
    clear_captured_output(output)
    TuiState.clear_activity(state)
    TuiState.put_workspace(state, nil)
    TuiState.clear_conversation(state)
    ConversationStore.clear(ConversationStore.project_dir(result))
    redraw(callbacks).(result, output, state, "", cols, rows)
    :continue
  end

  def handle("/answer " <> answer, result, output, state, cols, rows, callbacks) do
    close_overlay(state)
    TuiInteraction.submit_slash_answer(answer, result, output, state)
    redraw(callbacks).(result, output, state, "", cols, rows)
    :continue
  end

  def handle("/cancel", result, output, state, cols, rows, callbacks) do
    case TuiInteraction.submit_cancel(result, output, state) do
      :handled ->
        close_overlay(state)
        redraw(callbacks).(result, output, state, "", cols, rows)
        :continue

      :not_handled ->
        {:submit, "/cancel"}
    end
  end

  def handle("/exit", _result, _output, _state, _cols, _rows, _callbacks), do: :exit
  def handle("/quit", _result, _output, _state, _cols, _rows, _callbacks), do: :exit

  def handle(line, result, output, state, cols, rows, callbacks)
      when line in ["/provider", "/providers"] do
    TuiState.put_mode(state, :model)
    TuiState.put_pidx(state, 0)
    redraw(callbacks).(result, output, state, "", cols, rows)
    :continue
  end

  def handle("/" <> _ = line, result, _output, state, _cols, _rows, _callbacks) do
    maybe_put_workspace(line, result, state)
    {:submit, line}
  end

  def handle("ooo" <> _ = line, result, output, state, cols, rows, callbacks) do
    if auto_workflow?(line) do
      TuiState.put_workspace(state, WorkspaceModel.workflow_start(line))
    else
      TuiState.put_workspace(state, nil)
    end

    redraw(callbacks).(result, output, state, "", cols, rows)
    {:submit, line}
  end

  def handle(prompt, result, output, state, cols, rows, callbacks) do
    case TuiLogin.complete_paste(prompt, output, state) do
      :handled ->
        redraw(callbacks).(result, output, state, "", cols, rows)
        :continue

      :not_pending ->
        chat(prompt, result, output, state, cols, rows, callbacks)
    end
  end

  defp chat(prompt, result, output, state, cols, rows, callbacks) do
    TuiState.put_workspace(state, nil)

    TuiChat.chat(
      prompt,
      result,
      output,
      state,
      cols,
      rows,
      active_model(callbacks),
      redraw(callbacks)
    )

    :continue
  end

  defp redraw(callbacks), do: Keyword.fetch!(callbacks, :redraw)
  defp active_model(callbacks), do: Keyword.fetch!(callbacks, :active_model)

  defp log(output, text), do: IO.puts(output, text)

  defp close_overlay(state) do
    TuiState.put_mode(state, :normal)
    TuiState.put_pidx(state, 0)
  end

  defp clear_captured_output(output) do
    StringIO.flush(output)
    :ok
  rescue
    _exception -> :ok
  end

  defp maybe_put_workspace(line, result, state) do
    [command | args] = String.split(line, ~r/\s+/, parts: 2)

    if workspace_preview_command?(command, args) do
      tui_state = %{
        startup_result: display_result(result, state),
        pane_model: get_in(result, [:runtime, :pane_model]) || %{}
      }

      TuiState.put_workspace(state, WorkspaceModel.build(command, tui_state, %{}))
    else
      TuiState.put_workspace(state, nil)
    end
  end

  defp workspace_preview_command?("/resume", [_args]), do: false
  defp workspace_preview_command?(command, _args), do: WorkspaceModel.management_command?(command)

  defp display_result(result, state) do
    if TuiState.force_interview_paused?(state), do: Map.put(result, :paused, true), else: result
  end

  defp auto_workflow?(line) do
    normalized = line |> String.trim() |> String.downcase()
    normalized == "ooo auto" or String.starts_with?(normalized, "ooo auto ")
  end
end
