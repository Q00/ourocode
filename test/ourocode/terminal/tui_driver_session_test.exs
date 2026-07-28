defmodule Ourocode.Terminal.TuiDriverSessionTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{TuiDriverSession, TuiState}

  setup do
    state = TuiState.start_link()

    on_exit(fn ->
      if Process.alive?(state), do: Agent.stop(state)
    end)

    {:ok, state: state}
  end

  test "next_chunk drains buffered input before polling the helper", %{state: state} do
    TuiState.put_inbuf(state, "abc")

    assert TuiDriverSession.next_chunk(state, 0) == {:ok, "abc"}
    assert TuiDriverSession.next_chunk(state, 0) == :tick
  end

  test "next_chunk stores async file cache notifications and returns a repaint tick", %{
    state: state
  } do
    send(self(), {:file_cache_ready, ["lib/a.ex", "test/a_test.exs"]})

    assert TuiDriverSession.next_chunk(state, 0) == :tick
    assert TuiState.file_cache(state) == ["lib/a.ex", "test/a_test.exs"]
  end

  test "next_chunk stores helper resize events and returns typed resize", %{state: state} do
    send(self(), {nil, {:data, "\e]777;ourocode-resize=111x31\a"}})

    assert TuiDriverSession.next_chunk(state, 0) == {:resize, {111, 31}}
    assert TuiState.size(state) == {111, 31}
  end

  test "next_chunk forwards helper redraw control events without key decoding", %{state: state} do
    send(self(), {nil, {:data, "\e]777;ourocode-control=redraw\a"}})

    assert TuiDriverSession.next_chunk(state, 0) == {:control, :redraw}
  end

  test "next_chunk strips coalesced helper frame between raw input chunks", %{state: state} do
    send(self(), {nil, {:data, "a\e]777;ourocode-resize=111x31\ab"}})

    assert TuiDriverSession.next_chunk(state, 0) == {:ok, "a"}
    assert TuiDriverSession.next_chunk(state, 0) == {:resize, {111, 31}}
    assert TuiState.size(state) == {111, 31}
    assert TuiDriverSession.next_chunk(state, 0) == {:ok, "b"}
  end

  test "next_chunk ignores private helper frames inside coalesced raw input", %{state: state} do
    send(self(), {nil, {:data, "a\e]777;ourocode-control=bogus\ab"}})

    assert TuiDriverSession.next_chunk(state, 0) == {:ok, "a"}
    assert TuiDriverSession.next_chunk(state, 0) == :tick
    assert TuiDriverSession.next_chunk(state, 0) == {:ok, "b"}
  end

  test "terminal control sequences enable SGR mouse reporting for ledger inspection" do
    assert TuiDriverSession.enter_sequence() =~ "?1003h"
    assert TuiDriverSession.enter_sequence() =~ "?1006h"
    assert TuiDriverSession.exit_sequence() =~ "?1003l"
    assert TuiDriverSession.exit_sequence() =~ "?1006l"
  end
end
