defmodule Ourocode.Terminal.HistoryNavigationTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.HistoryNavigation

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        buffer: "",
        cursor: 0,
        history: ["ooo seed", "ooo interview"],
        history_index: 0,
        history_draft: nil,
        history_prefix: nil,
        ooo_cache: :cached,
        ooo_cache_loaded_ms: 123
      },
      overrides
    )
  end

  test "remember prepends unique entries and resets navigation state" do
    remembered =
      HistoryNavigation.remember(state(%{history_index: 1, history_draft: "draft"}), "ooo run", 3)

    assert remembered.history == ["ooo run", "ooo seed", "ooo interview"]
    assert remembered.history_index == 0
    assert remembered.history_draft == nil
    assert remembered.ooo_cache == nil
    assert remembered.ooo_cache_loaded_ms == nil
  end

  test "remember does not duplicate the newest history entry" do
    remembered = HistoryNavigation.remember(state(), "ooo seed", 3)
    assert remembered.history == ["ooo seed", "ooo interview"]
  end

  test "an empty prompt walks the whole history newest-first and anchors an empty draft" do
    first = HistoryNavigation.move(state(%{buffer: ""}), -1)
    assert first.buffer == "ooo seed"
    assert first.cursor == String.length("ooo seed")
    assert first.history_index == 1
    assert first.history_draft == ""

    second = HistoryNavigation.move(first, -1)
    assert second.buffer == "ooo interview"
    assert second.history_index == 2
    assert second.history_draft == ""
  end

  test "a typed prefix filters recall to entries starting with it and skips the rest" do
    start =
      state(%{
        buffer: "ooo",
        cursor: 3,
        history: ["ooo seed", "git status", "ooo interview"]
      })

    first = HistoryNavigation.move(start, -1)
    assert first.buffer == "ooo seed"
    assert first.history_index == 1
    assert first.history_prefix == "ooo"

    # Skips "git status" (index 2) and lands on the next "ooo" entry.
    second = HistoryNavigation.move(first, -1)
    assert second.buffer == "ooo interview"
    assert second.history_index == 3

    # No older match: the buffer stays put.
    third = HistoryNavigation.move(second, -1)
    assert third.buffer == "ooo interview"
    assert third.history_index == 3
  end

  test "paging newer past the newest match restores the typed prefix" do
    browsing =
      %{buffer: "ooo", cursor: 3, history: ["ooo seed", "git status", "ooo interview"]}
      |> state()
      |> HistoryNavigation.move(-1)
      |> HistoryNavigation.move(-1)

    assert browsing.buffer == "ooo interview"

    newer = HistoryNavigation.move(browsing, 1)
    assert newer.buffer == "ooo seed"
    assert newer.history_index == 1

    draft = HistoryNavigation.move(newer, 1)
    assert draft.buffer == "ooo"
    assert draft.cursor == 3
    assert draft.history_index == 0
    assert draft.history_draft == nil
  end

  test "move down returns through history to the original draft" do
    at_oldest =
      state(%{
        buffer: "ooo interview",
        cursor: String.length("ooo interview"),
        history_index: 2,
        history_draft: "current draft"
      })

    newer = HistoryNavigation.move(at_oldest, 1)
    assert newer.buffer == "ooo seed"
    assert newer.history_index == 1

    draft = HistoryNavigation.move(newer, 1)
    assert draft.buffer == "current draft"
    assert draft.cursor == String.length("current draft")
    assert draft.history_index == 0
    assert draft.history_draft == nil
  end

  test "reset clears only the history cursor" do
    reset =
      HistoryNavigation.reset(state(%{buffer: "keep", history_index: 1, history_draft: "draft"}))

    assert reset.buffer == "keep"
    assert reset.history_index == 0
    assert reset.history_draft == nil
  end
end
