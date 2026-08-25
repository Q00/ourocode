defmodule Ourocode.Terminal.PromptStoreTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.PromptStore

  defp tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ourocode-prompt-store-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.rm_rf!(dir)
    dir
  end

  test "persists prompt history as newest-first unique entries" do
    dir = tmp_dir()

    assert :ok = PromptStore.append_history("ooo interview", state_dir: dir)
    assert :ok = PromptStore.append_history("ooo seed", state_dir: dir)
    assert :ok = PromptStore.append_history("ooo interview", state_dir: dir)

    assert PromptStore.load_history(state_dir: dir) == ["ooo interview", "ooo seed"]
  end

  test "persists and clears the current draft" do
    dir = tmp_dir()

    assert PromptStore.load_draft(state_dir: dir) == ""
    assert :ok = PromptStore.save_draft("ask about @lib/ourocode", state_dir: dir)
    assert PromptStore.load_draft(state_dir: dir) == "ask about @lib/ourocode"
    assert :ok = PromptStore.clear_draft(state_dir: dir)
    assert PromptStore.load_draft(state_dir: dir) == ""
  end

  test "derives command usage counts from persisted history" do
    dir = tmp_dir()

    PromptStore.append_history("ooo interview build this", state_dir: dir)
    PromptStore.append_history("ooo interview refine it", state_dir: dir)
    PromptStore.append_history("ooo interview refine it", state_dir: dir)
    PromptStore.append_history("/status", state_dir: dir)

    assert PromptStore.command_usage(state_dir: dir) == %{
             "ooo interview" => 3,
             "/status" => 1
           }
  end

  test "compacts prompt history to a bounded file" do
    dir = tmp_dir()

    Enum.each(1..2_000, fn index ->
      PromptStore.append_history("/status #{index} " <> String.duplicate("x", 200),
        state_dir: dir
      )
    end)

    path = Path.join(dir, "prompt_history.jsonl")
    assert File.stat!(path).size <= 262_144
    assert length(PromptStore.load_history(state_dir: dir)) == 50
    assert PromptStore.command_usage(state_dir: dir)["/status"] <= 1_000
  end
end
