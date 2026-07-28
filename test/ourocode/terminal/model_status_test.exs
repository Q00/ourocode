defmodule Ourocode.Terminal.ModelStatusTest do
  use ExUnit.Case, async: true

  alias Ourocode.Model
  alias Ourocode.Terminal.ModelStatus

  test "active_model reuses a fresh cache entry for the selected model id" do
    cached = model(:cached, "cached")

    current = %{
      model_id: :cached,
      model_cache: %{id: :cached, expires_at: 200, model: cached}
    }

    assert {^cached, ^current} =
             ModelStatus.active_model(current, 100, 50, [model(:other, "other")], fn ->
               flunk("default model should not be loaded for fresh cache")
             end)
  end

  test "active_model refreshes stale cache from listed models" do
    selected = model(:selected, "selected")

    current = %{
      model_id: :selected,
      model_cache: %{id: :selected, expires_at: 99, model: model(:old, "old")}
    }

    assert {^selected, updated} =
             ModelStatus.active_model(current, 100, 50, [selected], fn ->
               model(:default, "default")
             end)

    assert updated.model_cache == %{id: :selected, expires_at: 150, model: selected}
  end

  test "active_model falls back to the default model when selection is missing" do
    default = model(:default, "default")

    assert {^default, updated} =
             ModelStatus.active_model(%{model_id: :missing, model_cache: nil}, 100, 50, [], fn ->
               default
             end)

    assert updated.model_cache.model == default
  end

  test "auth_label renders ready, auth-needed, and missing model states" do
    assert ModelStatus.auth_label(model(:ready, "ready", :ready)) == {"model: ready", :ok}

    assert ModelStatus.auth_label(model(:codex, "codex", {:needs_auth, "/login"})) ==
             {"model: codex  /login", :dim}

    assert ModelStatus.auth_label(nil) == {"no model  -  /model", :dim}
  end

  test "hud_status separates provider and model slug with optional latency" do
    codex = model(:codex, "codex  (ChatGPT)")

    assert ModelStatus.hud_status(codex, "gpt-5.3-codex", 1_234) ==
             "provider: codex  (ChatGPT)  model: gpt-5.3-codex · 1.2s"

    assert ModelStatus.hud_status(codex, "", 42) == "provider: codex  (ChatGPT) · 42ms"
    assert ModelStatus.hud_status(codex, nil, nil) == "provider: codex  (ChatGPT)"
  end

  defp model(id, label, status \\ :ready) do
    %Model{
      id: id,
      label: label,
      kind: :cli,
      status: status,
      run: fn _prompt, _opts, _on_chunk -> {:ok, ""} end
    }
  end
end
