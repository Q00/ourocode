defmodule Ourocode.Terminal.TuiChatTest do
  # async: false — the persistence test points OUROCODE_STATE_DIR at a tmp dir.
  use ExUnit.Case, async: false

  alias Ourocode.Model
  alias Ourocode.Model.Conversation
  alias Ourocode.Terminal.{TuiChat, TuiState}

  test "chat threads the conversation into the model and stores the completed turn" do
    state = TuiState.start_link()
    # The state agent is linked to the test process and dies with it.
    {:ok, output} = StringIO.open("")
    parent = self()

    model = %Model{
      id: :fake,
      label: "fake",
      kind: :cli,
      status: :ready,
      run: fn prompt, opts, on_chunk ->
        send(parent, {:ran, prompt, Keyword.get(opts, :history)})
        on_chunk.("pong")
        {:ok, "pong"}
      end
    }

    redraw = fn _result, _output, _state, _buffer, _cols, _rows -> :ok end

    TuiChat.chat("ping", %{}, output, state, 80, 24, fn _state -> model end, redraw)

    assert_received {:ran, "ping", %Conversation{turns: []}}
    assert TuiState.conversation(state).turns == [%{user: "ping", assistant: "pong"}]

    # The second turn receives the first exchange as history.
    TuiChat.chat("again", %{}, output, state, 80, 24, fn _state -> model end, redraw)

    assert_received {:ran, "again", %Conversation{turns: [%{user: "ping", assistant: "pong"}]}}

    TuiState.clear_conversation(state)
    assert Conversation.empty?(TuiState.conversation(state))
  end

  test "chat passes the active Codex model slug as a session-sourced model opt" do
    state = TuiState.start_link()
    TuiState.put_model_id(state, :codex)
    TuiState.put_provider_model_slug(state, :codex, "gpt-5.3-codex")

    {:ok, output} = StringIO.open("")
    parent = self()

    model = %Model{
      id: :codex,
      label: "codex  (ChatGPT)",
      kind: :oauth,
      status: :ready,
      run: fn prompt, opts, on_chunk ->
        send(parent, {:ran, prompt, Keyword.get(opts, :model), Keyword.get(opts, :model_source)})
        on_chunk.("pong")
        {:ok, "pong"}
      end
    }

    redraw = fn _result, _output, _state, _buffer, _cols, _rows -> :ok end

    TuiChat.chat("ping", %{}, output, state, 80, 24, fn _state -> model end, redraw)

    assert_received {:ran, "ping", "gpt-5.3-codex", :session}
  end

  test "the conversation survives a TUI restart for the same project" do
    state_dir =
      Path.join(System.tmp_dir!(), "ourocode-chat-persist-#{System.unique_integer([:positive])}")

    File.mkdir_p!(state_dir)
    original = System.get_env("OUROCODE_STATE_DIR")
    System.put_env("OUROCODE_STATE_DIR", state_dir)

    on_exit(fn ->
      if original,
        do: System.put_env("OUROCODE_STATE_DIR", original),
        else: System.delete_env("OUROCODE_STATE_DIR")

      File.rm_rf(state_dir)
    end)

    result = %{context: %{project_dir: "/tmp/persist-project"}}
    parent = self()

    model = %Model{
      id: :fake,
      label: "fake",
      kind: :cli,
      status: :ready,
      run: fn _prompt, opts, on_chunk ->
        send(parent, {:history, Keyword.get(opts, :history)})
        on_chunk.("pong")
        {:ok, "pong"}
      end
    }

    redraw = fn _result, _output, _state, _buffer, _cols, _rows -> :ok end

    # First run: one exchange, persisted on completion.
    first_state = TuiState.start_link()
    {:ok, first_output} = StringIO.open("")

    TuiChat.chat(
      "ping",
      result,
      first_output,
      first_state,
      80,
      24,
      fn _state -> model end,
      redraw
    )

    assert_received {:history, %Conversation{turns: []}}
    Agent.stop(first_state)

    # Second run (fresh TuiState = restarted TUI): history is restored.
    second_state = TuiState.start_link()
    {:ok, second_output} = StringIO.open("")

    TuiChat.chat(
      "again",
      result,
      second_output,
      second_state,
      80,
      24,
      fn _state -> model end,
      redraw
    )

    assert_received {:history, %Conversation{turns: [%{user: "ping", assistant: "pong"}]}}
  end

  test "a bare Esc cancels the in-flight turn without polluting the conversation" do
    state = TuiState.start_link()
    {:ok, output} = StringIO.open("")

    model = %Model{
      id: :fake,
      label: "fake",
      kind: :cli,
      status: :ready,
      run: fn _prompt, _opts, _on_chunk -> Process.sleep(:infinity) end
    }

    # Pre-queue the keystroke the tty port would deliver (the port is nil in
    # tests, matching the `{^port, {:data, ...}}` clause).
    send(self(), {nil, {:data, <<27>>}})

    redraw = fn _result, _output, _state, _buffer, _cols, _rows -> :ok end
    TuiChat.chat("ping", %{}, output, state, 80, 24, fn _state -> model end, redraw)

    {_in, text} = StringIO.contents(output)
    assert text =~ "turn cancelled"
    assert Conversation.empty?(TuiState.conversation(state))
  end

  test "keystrokes typed during a turn are re-buffered for the input loop" do
    state = TuiState.start_link()
    {:ok, output} = StringIO.open("")

    model = %Model{
      id: :fake,
      label: "fake",
      kind: :cli,
      status: :ready,
      run: fn _prompt, _opts, on_chunk ->
        on_chunk.("pong")
        {:ok, "pong"}
      end
    }

    send(self(), {nil, {:data, "a"}})

    redraw = fn _result, _output, _state, _buffer, _cols, _rows -> :ok end
    TuiChat.chat("ping", %{}, output, state, 80, 24, fn _state -> model end, redraw)

    assert TuiState.take_inbuf(state) == "a"
    assert TuiState.conversation(state).turns == [%{user: "ping", assistant: "pong"}]
  end

  test "the first streamed chunk records time-to-first-token for the footer" do
    state = TuiState.start_link()
    {:ok, output} = StringIO.open("")

    model = %Model{
      id: :fake,
      label: "fake",
      kind: :cli,
      status: :ready,
      run: fn _prompt, _opts, on_chunk ->
        on_chunk.("pong")
        {:ok, "pong"}
      end
    }

    assert TuiState.last_turn_ms(state) == nil

    redraw = fn _result, _output, _state, _buffer, _cols, _rows -> :ok end
    TuiChat.chat("ping", %{}, output, state, 80, 24, fn _state -> model end, redraw)

    ms = TuiState.last_turn_ms(state)
    assert is_integer(ms) and ms >= 0
  end

  test "a failed turn leaves the conversation unchanged" do
    state = TuiState.start_link()
    # The state agent is linked to the test process and dies with it.
    {:ok, output} = StringIO.open("")

    model = %Model{
      id: :fake,
      label: "fake",
      kind: :cli,
      status: :ready,
      run: fn _prompt, _opts, _on_chunk -> {:error, :timeout} end
    }

    redraw = fn _result, _output, _state, _buffer, _cols, _rows -> :ok end
    TuiChat.chat("ping", %{}, output, state, 80, 24, fn _state -> model end, redraw)

    assert Conversation.empty?(TuiState.conversation(state))
  end
end
