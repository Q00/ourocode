defmodule Ourocode.Runtime.LoopBindingInterviewAwaiter do
  @moduledoc """
  State transforms for pausing an interview loop until a user answer arrives.
  """

  alias Ourocode.Runtime.{InterviewResponse, InterviewWonderPrompt, LoopBindingInterviewText}

  @spec await(pid(), term(), term(), [map()]) :: {:done, String.t()} | {:answer, String.t()}
  def await(agent, parent_call_id, prompt, options \\ []) when is_pid(agent) do
    waiter = self()
    owner_ref = Process.monitor(agent)

    Agent.update(agent, fn state ->
      wait_state(state, parent_call_id, prompt, waiter, options)
    end)

    receive do
      {:interview_answer, text} ->
        Process.demonitor(owner_ref, [:flush])
        classify_answer(text)

      {:DOWN, ^owner_ref, :process, ^agent, _reason} ->
        {:done, "cancel"}
    end
  end

  @spec wait_state(map(), term(), term(), pid(), [map()]) :: map()
  def wait_state(state, parent_call_id, prompt, waiter, options \\ [])
      when is_map(state) and is_pid(waiter) do
    prev = Map.get(state, :interview) || %{}
    prompt = InterviewResponse.clean_markdown(prompt)

    iv =
      prev
      |> Map.merge(%{
        question: prompt,
        question_options: InterviewWonderPrompt.options(options, prompt),
        parent_call_id: parent_call_id || prev[:parent_call_id],
        waiting: false,
        status: "waiting for your answer"
      })
      |> Map.delete(:answered)
      |> Map.delete(:waiting_started_monotonic_ms)

    state
    |> Map.put(:interview, iv)
    |> Map.put(:interview_waiter, waiter)
    |> Map.put(:paused, false)
  end

  @spec classify_answer(String.t()) :: {:done, String.t()} | {:answer, String.t()}
  def classify_answer(text) when is_binary(text) do
    if LoopBindingInterviewText.user_terminated?(text),
      do: {:done, text},
      else: {:answer, text}
  end
end
