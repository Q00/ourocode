defmodule Ourocode.Terminal.TuiInputLoopTest do
  use ExUnit.Case, async: false

  alias Ourocode.Terminal.{TuiInputLoop, TuiState}

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ourocode-tui-input-loop-#{System.unique_integer([:positive])}"
      )

    previous = System.get_env("OUROCODE_STATE_DIR")
    System.put_env("OUROCODE_STATE_DIR", dir)

    {:ok, output} = StringIO.open("")
    state = TuiState.start_link()
    parent = self()

    on_exit(fn ->
      if previous,
        do: System.put_env("OUROCODE_STATE_DIR", previous),
        else: System.delete_env("OUROCODE_STATE_DIR")

      if Process.alive?(state), do: Agent.stop(state)
      File.rm_rf!(dir)
    end)

    %{callbacks: callbacks(parent), output: output, state: state}
  end

  test "char input edits the composer and redraws", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    assert TuiInputLoop.handle_events(
             [%{key: :char, char: "a"}],
             %{},
             output,
             state,
             80,
             24,
             callbacks
           ) == :continue

    assert TuiState.buffer(state) == "a"
    assert_received {:redraw, "a", 80, 24}
  end

  test "enter submits the trimmed composer line", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    TuiState.edit_buffer(state, %{key: :paste, char: "  hello  "})

    assert TuiInputLoop.handle_events(
             [%{key: :enter}],
             %{},
             output,
             state,
             100,
             30,
             callbacks
           ) == {:submit, "hello"}

    assert TuiState.buffer(state) == ""
    assert_received {:handle_enter, "hello", 100, 30}
  end

  test "tab completes a partial ooo command", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    TuiState.edit_buffer(state, %{key: :paste, char: "ooo int"})

    assert TuiInputLoop.handle_events(
             [%{key: :tab}],
             %{},
             output,
             state,
             80,
             24,
             callbacks
           ) == :continue

    assert TuiState.buffer(state) == "ooo interview "
    assert_received {:redraw, "ooo interview ", 80, 24}
  end

  test "ctrl-c exits before later events are applied", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    assert TuiInputLoop.handle_events(
             [%{key: :ctrl_c}, %{key: :char, char: "x"}],
             %{},
             output,
             state,
             80,
             24,
             callbacks
           ) == :exit

    assert TuiState.buffer(state) == ""
  end

  test "tick flushes a buffered standalone escape immediately", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    parent = self()
    TuiState.put_leftover(state, <<27>>)

    result = %{
      pane_snapshot: fn -> %{wonder_tool: detection(), paused: false} end,
      wonder_answer: fn _payload -> {:ok, %{}} end,
      wonder_pause: fn -> send(parent, :paused) end
    }

    assert TuiInputLoop.handle_tick(result, output, state, 80, 24, callbacks) == :continue
    assert_received :paused
    assert TuiState.take_leftover(state) == ""
  end

  test "tick preserves incomplete escape sequences", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    TuiState.put_leftover(state, <<27, ?[>>)

    assert TuiInputLoop.handle_tick(%{}, output, state, 80, 24, callbacks) == :continue
    assert TuiState.take_leftover(state) == <<27, ?[>>
  end

  test "slash input while forced paused stays in the composer", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    TuiState.put_force_interview_paused(state, true)

    assert TuiInputLoop.handle_events(
             [%{key: :char, char: "/"}],
             %{},
             output,
             state,
             80,
             24,
             callbacks
           ) == :continue

    assert TuiState.mode(state) == :normal
    assert TuiState.buffer(state) == "/"
    assert_received {:redraw, "/", 80, 24}
  end

  test "slash enter during an active interview dispatches the command instead of answering", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    TuiState.edit_buffer(state, %{key: :paste, char: "/agents"})

    result = %{
      pane_snapshot: fn -> %{wonder_tool: detection(), paused: false} end,
      wonder_answer: fn _payload ->
        send(self(), :unexpected_answer)
        {:ok, %{}}
      end
    }

    assert TuiInputLoop.handle_events(
             [%{key: :enter}],
             result,
             output,
             state,
             80,
             24,
             callbacks
           ) == {:submit, "/agents"}

    assert_received {:handle_enter, "/agents", 80, 24}
    refute_received :unexpected_answer
  end

  test "ooo enter during an active interview dispatches the workflow instead of answering", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    TuiState.edit_buffer(state, %{key: :paste, char: "ooo pm build onboarding"})

    result = %{
      pane_snapshot: fn -> %{wonder_tool: detection(), paused: false} end,
      wonder_answer: fn _payload ->
        send(self(), :unexpected_answer)
        {:ok, %{}}
      end
    }

    assert TuiInputLoop.handle_events(
             [%{key: :enter}],
             result,
             output,
             state,
             80,
             24,
             callbacks
           ) == {:submit, "ooo pm build onboarding"}

    assert_received {:handle_enter, "ooo pm build onboarding", 80, 24}
    refute_received :unexpected_answer
  end

  test "slash input during active interview stays in composer instead of opening palette", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    result = %{pane_snapshot: fn -> %{wonder_tool: detection(), paused: false} end}

    assert TuiInputLoop.handle_events(
             [%{key: :char, char: "/"}],
             result,
             output,
             state,
             80,
             24,
             callbacks
           ) == :continue

    assert TuiState.mode(state) == :normal
    assert TuiState.buffer(state) == "/"
    refute_received {:redraw, "/", 80, 24}
  end

  test "arrow keys move plain interview options without mouse focus", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    result = %{
      pane_snapshot: fn ->
        %{
          interview: %{
            question: "Which email service first?",
            question_options: [
              %{label: "Gmail", description: "Google inboxes"},
              %{label: "Outlook", description: "Microsoft inboxes"}
            ]
          },
          paused: false
        }
      end
    }

    assert TuiInputLoop.handle_events(
             [%{key: :down}],
             result,
             output,
             state,
             80,
             24,
             callbacks
           ) == :continue

    assert TuiState.wonder_nav(state).picks == %{0 => 1}
    assert_received {:redraw, "", 80, 24}
  end

  test "MCP-only ledger keyboard navigation reaches interaction handler through input loop", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    first_id = "ledger:child:tool-call-1"
    second_id = "ledger:child:tool-call-2"

    TuiState.put_mcp_ledger_hit_map(state, %{
      12 => %{id: first_id, x1: 60, x2: 110},
      13 => %{id: second_id, x1: 60, x2: 110}
    })

    assert TuiInputLoop.handle_events(
             [%{key: :char, char: "1"}, %{key: :down}, %{key: :enter}],
             %{},
             output,
             state,
             100,
             30,
             callbacks
           ) == :continue

    assert TuiState.mcp_ledger_selected_id(state) == second_id
    assert hd(TuiState.notifications(state)) == "tool call opened"
    assert_received {:redraw, "", 100, 30}
  end

  test "MCP-only ledger input loop supports every advertised keyboard selector", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    ids = install_mcp_ledger_hit_map(state)

    steps = [
      {%{key: :char, char: "1"}, Enum.at(ids, 0)},
      {%{key: :char, char: "+"}, Enum.at(ids, 1)},
      {%{key: :char, char: "j"}, Enum.at(ids, 2)},
      {%{key: :char, char: "k"}, Enum.at(ids, 1)},
      {%{key: :down}, Enum.at(ids, 2)},
      {%{key: :up}, Enum.at(ids, 1)},
      {%{key: :char, char: "-"}, Enum.at(ids, 0)},
      {%{key: :char, char: "3"}, Enum.at(ids, 2)}
    ]

    Enum.each(steps, fn {event, expected_id} ->
      assert TuiInputLoop.handle_events([event], %{}, output, state, 100, 30, callbacks) ==
               :continue

      assert TuiState.mcp_ledger_selected_id(state) == expected_id
    end)

    assert TuiInputLoop.handle_events([%{key: :enter}], %{}, output, state, 100, 30, callbacks) ==
             :continue

    assert hd(TuiState.notifications(state)) == "tool call opened"

    Enum.each(1..9, fn number ->
      assert TuiInputLoop.handle_events(
               [%{key: :char, char: Integer.to_string(number)}],
               %{},
               output,
               state,
               100,
               30,
               callbacks
             ) == :continue

      assert TuiState.mcp_ledger_selected_id(state) == Enum.at(ids, number - 1)
    end)
  end

  test "tick does not redraw a pending cancel prefix during active interview", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    TuiState.edit_buffer(state, %{key: :paste, char: "/canc"})
    result = %{pane_snapshot: fn -> %{interview: %{complete: false, status: "opening"}} end}

    assert TuiInputLoop.handle_tick(result, output, state, 80, 24, callbacks) == :continue

    refute_received {:redraw, "/canc", 80, 24}
  end

  test "tick redraws non-cancel slash input during active interview", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    TuiState.edit_buffer(state, %{key: :paste, char: "/agents"})
    result = %{pane_snapshot: fn -> %{interview: %{complete: false, status: "opening"}} end}

    assert TuiInputLoop.handle_tick(result, output, state, 80, 24, callbacks) == :continue

    assert_received {:redraw, "/agents", 80, 24}
  end

  defp callbacks(parent) do
    %{
      choose_model: fn _result, _output, _state, columns, rows ->
        send(parent, {:choose_model, columns, rows})
        :ok
      end,
      handle_enter: fn line, _result, _output, _state, columns, rows ->
        send(parent, {:handle_enter, line, columns, rows})
        {:submit, line}
      end,
      redraw: fn _result, _output, state, _prompt_buffer, columns, rows ->
        send(parent, {:redraw, TuiState.buffer(state), columns, rows})
        :ok
      end,
      test_run?: fn -> true end
    }
  end

  defp install_mcp_ledger_hit_map(state) do
    ids = Enum.map(1..9, &"ledger:child:tool-call-#{&1}")

    hit_map =
      ids
      |> Enum.with_index(12)
      |> Map.new(fn {id, row} -> {row, %{id: id, x1: 60, x2: 110}} end)

    TuiState.put_mcp_ledger_hit_map(state, hit_map)
    ids
  end

  defp detection do
    %{
      request: %{
        tool: :wonder_tool,
        type: :multiple_choice_decision,
        questions: [
          %{
            id: "first",
            header: "First",
            question: "Pick one",
            options: [%{label: "a", description: "a description"}]
          }
        ]
      }
    }
  end
end
