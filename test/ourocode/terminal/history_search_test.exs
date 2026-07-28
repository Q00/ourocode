defmodule Ourocode.Terminal.HistorySearchTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.HistorySearch

  # Stored newest-first.
  @history ["ooo pm design", "git status", "ooo auto ship", "make test"]

  test "finds the most recent substring match" do
    assert HistorySearch.find(@history, "ooo") == {"ooo pm design", 1}
    assert HistorySearch.find(@history, "status") == {"git status", 2}
  end

  test "skip walks toward older matches, then reports :none" do
    assert HistorySearch.find(@history, "ooo", 0) == {"ooo pm design", 1}
    assert HistorySearch.find(@history, "ooo", 1) == {"ooo auto ship", 3}
    assert HistorySearch.find(@history, "ooo", 2) == :none
  end

  test "an empty query matches the newest entry" do
    assert HistorySearch.find(@history, "") == {"ooo pm design", 1}
  end

  test "returns :none when nothing matches" do
    assert HistorySearch.find(@history, "zzz") == :none
  end
end
