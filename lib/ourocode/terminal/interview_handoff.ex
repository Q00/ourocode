defmodule Ourocode.Terminal.InterviewHandoff do
  @moduledoc """
  Helpers for the paused-interview main-session handoff protocol.
  """

  @spec prompt(String.t(), String.t()) :: String.t()
  def prompt(question, user_message) do
    prompt = """
    You are the main ourocode session. An interview checkpoint is paused so
    the user can discuss it with you before answering.

    Pending interview question:
    #{question}

    User message:
    #{user_message}

    Reply normally. If, and only if, your reply is ready to be submitted as
    the final answer to the pending interview question, include a final line:
    INTERVIEW_ANSWER: <concise answer to submit>
    Do not include that line for clarifications, translations, explanations,
    or ordinary discussion.
    """

    String.replace(prompt, "\r\n", "\n")
  end

  @spec extract_answer(term()) :: String.t() | nil
  def extract_answer(full) when is_binary(full) do
    full
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^\s*INTERVIEW_ANSWER:\s*(.+?)\s*$/u, line) do
        [_, answer] -> String.trim(answer)
        _none -> nil
      end
    end)
  end

  def extract_answer(_full), do: nil
end
