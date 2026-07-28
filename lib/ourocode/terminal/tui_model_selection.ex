defmodule Ourocode.Terminal.TuiModelSelection do
  @moduledoc """
  Provider selection, active-model cache, and provider-picker actions for the raw TUI.
  """

  alias Ourocode.Model
  alias Ourocode.Model.Catalog
  alias Ourocode.Terminal.{ModelStatus, TuiState}

  @spec active_model(pid(), pos_integer()) :: Model.t()
  def active_model(state, cache_ttl_ms) when is_pid(state) and is_integer(cache_ttl_ms) do
    now = System.monotonic_time(:millisecond)

    Agent.get_and_update(state, fn current ->
      models = Catalog.list()
      ModelStatus.active_model(current, now, cache_ttl_ms, models, &Catalog.default/0)
    end)
  end

  @spec auth_label(pid(), pos_integer()) :: ModelStatus.auth_label()
  def auth_label(state, cache_ttl_ms) do
    state
    |> active_model(cache_ttl_ms)
    |> ModelStatus.auth_label()
  end

  @spec overlay(pid()) :: %{
          required(:models) => [Model.t()],
          required(:index) => non_neg_integer()
        }
  def overlay(state) when is_pid(state) do
    models = Catalog.selectable(Catalog.list())
    %{models: models, index: selected_index(TuiState.pidx(state), length(models))}
  end

  @spec selected([Model.t()], integer()) :: Model.t() | nil
  def selected(models, index) when is_list(models) and is_integer(index) do
    Enum.at(models, selected_index(index, length(models)))
  end

  @spec selected_index(integer(), non_neg_integer()) :: non_neg_integer()
  def selected_index(_index, 0), do: 0
  def selected_index(index, count), do: Integer.mod(index, count)

  @spec choose(map(), StringIO.oneline(), pid(), pos_integer(), pos_integer(), keyword()) :: :ok
  def choose(result, output, state, cols, rows, opts)
      when is_pid(state) and is_list(opts) do
    models = Keyword.get_lazy(opts, :models, fn -> Catalog.selectable(Catalog.list()) end)
    redraw = Keyword.fetch!(opts, :redraw)
    login = Keyword.fetch!(opts, :login)
    log = Keyword.get(opts, :log, &IO.puts/2)

    selected_model = selected(models, TuiState.pidx(state))
    close_picker(state)

    cond do
      selected_model == nil ->
        redraw.(result, output, state, "", cols, rows)

      Model.ready?(selected_model) ->
        TuiState.put_model_id(state, selected_model.id)
        log.(output, "provider: #{selected_model.label}")
        redraw.(result, output, state, "", cols, rows)

      Model.needs_auth?(selected_model) ->
        TuiState.put_model_id(state, selected_model.id)
        login.(selected_model.id, result, output, state, cols, rows, redraw)

      true ->
        log.(output, "#{selected_model.label} is not ready.")
        redraw.(result, output, state, "", cols, rows)
    end
  end

  defp close_picker(state) do
    TuiState.put_mode(state, :normal)
    _ = TuiState.take_buffer(state)
    TuiState.put_pidx(state, 0)
  end
end
