defmodule Ourocode.Model.ProfileTest do
  use ExUnit.Case, async: true

  alias Ourocode.Model
  alias Ourocode.Model.Profile

  test "interview profile prefers a ready precision model" do
    profile =
      Profile.for_route(:interview,
        models: [
          model(:codex, "codex", :ready),
          model(:claude_api, "claude api", :ready)
        ]
      )

    assert profile.id == :deep_interview
    assert profile.label == "interview/precision"
    assert profile.model_id == :claude_api
    assert profile.llm_backend == "claude_code"
  end

  test "execution profiles prefer Codex even when Claude is ready" do
    profile =
      Profile.for_route(:evolve,
        models: [
          model(:claude_api, "claude api", :ready),
          model(:codex, "codex", :ready)
        ]
      )

    assert profile.id == :execute
    assert profile.label == "evolve/codex"
    assert profile.model_id == :codex
    assert profile.llm_backend == "codex"
  end

  test "falls back to the active model when no profile candidate is ready" do
    active = model(:gemini, "gemini cli", :ready)

    profile =
      Profile.for_route(:run,
        active_model: active,
        models: [
          model(:codex, "codex", :unavailable),
          model(:claude_api, "claude api", :unavailable)
        ]
      )

    assert profile.model == active
    assert profile.llm_backend == "gemini"
  end

  test "prefers the active model instance when it is a ready profile candidate" do
    active = model(:codex, "codex fake runner", :ready)

    profile =
      Profile.for_route(:pm,
        active_model: active,
        models: [
          model(:claude_api, "claude api", :unavailable),
          model(:codex, "catalog codex", :ready)
        ]
      )

    assert profile.model == active
    assert profile.model_label == "codex fake runner"
  end

  test "display label uses product-facing role language" do
    assert Profile.display_label(%{label: "execute/codex", model_label: "codex  (ChatGPT)"}) ==
             "Execute · Codex Runtime"

    assert Profile.display_label(%{
             "label" => "interview/precision",
             "model_label" => "claude  (Claude Pro/Max)"
           }) ==
             "Socratic Interview · Precision"
  end

  test "short_model_label removes vendor parentheticals for tight terminal rows" do
    assert Profile.short_model_label("codex  (ChatGPT)") == "codex"
    assert Profile.short_model_label("claude  (Claude Pro/Max)") == "claude"
  end

  defp model(id, label, status) do
    %Model{id: id, label: label, kind: :cli, status: status, run: fn _, _, _ -> :ok end}
  end
end
