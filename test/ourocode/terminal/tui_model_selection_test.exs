defmodule Ourocode.Terminal.TuiModelSelectionTest do
  use ExUnit.Case, async: true

  alias Ourocode.Model
  alias Ourocode.Terminal.{TuiModelSelection, TuiState}

  test "selected wraps an unbounded picker index across available models" do
    models = [model(:alpha, "alpha"), model(:bravo, "bravo"), model(:charlie, "charlie")]

    assert %Model{id: :alpha} = TuiModelSelection.selected(models, 0)
    assert %Model{id: :bravo} = TuiModelSelection.selected(models, 4)
    assert %Model{id: :charlie} = TuiModelSelection.selected(models, -1)
    assert TuiModelSelection.selected([], 10) == nil
  end

  test "choose stores ready provider selection, invalidates cache, logs it, and closes picker mode" do
    state = TuiState.start_link()
    TuiState.put_mode(state, :model)
    TuiState.put_pidx(state, 1)
    {:ok, output} = StringIO.open("")

    Agent.update(state, fn current ->
      %{
        current
        | model_cache: %{
            id: :alpha,
            expires_at: System.monotonic_time(:millisecond) + 60_000,
            model: model(:alpha, "alpha")
          }
      }
    end)

    TuiModelSelection.choose(%{}, output, state, 80, 24,
      models: [model(:alpha, "alpha"), model(:bravo, "bravo")],
      redraw: fn _result, _output, _state, _buffer, _cols, _rows -> :ok end,
      login: fn _provider, _result, _output, _state, _cols, _rows, _redraw -> :ok end
    )

    {_input, captured} = StringIO.contents(output)
    current = Agent.get(state, & &1)

    assert captured =~ "provider: bravo"
    assert current.model_id == :bravo
    assert current.model_cache == nil
    assert current.mode == :normal
    assert current.pidx == 0
  end

  test "choose delegates any auth-needed model to its login flow with the provider id" do
    for {id, hint} <- [{:codex, "/login"}, {:claude_api, "/login-claude"}] do
      state = TuiState.start_link()
      TuiState.put_mode(state, :model)
      {:ok, output} = StringIO.open("")
      parent = self()

      TuiModelSelection.choose(%{}, output, state, 80, 24,
        models: [model(id, to_string(id), {:needs_auth, hint})],
        redraw: fn _result, _output, _state, _buffer, _cols, _rows -> :ok end,
        login: fn provider, _result, _output, _state, cols, rows, _redraw ->
          send(parent, {:login_started, provider, cols, rows})
        end
      )

      assert_receive {:login_started, ^id, 80, 24}
      assert Agent.get(state, & &1.model_id) == id
    end
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
