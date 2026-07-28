defmodule Ourocode.Terminal.QaFramesTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.QaFrames

  test "builds browser QA frames from current TUI renderer" do
    frames = QaFrames.all()

    assert length(frames) >= 6
    assert Enum.all?(frames, &is_binary(&1.text))
    assert Enum.any?(frames, &(&1.title == "Answer the interview"))
    assert Enum.any?(frames, &String.contains?(&1.text, "INTERVIEW"))
    assert Enum.all?(frames, &(is_integer(&1.duration_ms) and &1.duration_ms > 0))
    assert Enum.all?(frames, &(is_list(&1.checks) and &1.checks != []))
  end

  test "exports frame payload as json" do
    assert {:ok, decoded} = Ourocode.Json.decode(QaFrames.all_json())
    assert is_list(decoded)
    assert decoded |> List.first() |> Map.fetch!("title") == "Start"
  end
end
