defmodule Ourocode.Terminal.ModelStatus do
  @moduledoc """
  Pure model status helpers for the raw TUI.
  """

  alias Ourocode.Model
  alias Ourocode.Model.Catalog

  @type auth_label :: {String.t(), :ok | :dim}

  @spec active_model(map(), integer(), pos_integer(), [Model.t()], (-> Model.t())) ::
          {Model.t(), map()}
  def active_model(current, now_ms, ttl_ms, models, default_model_fun)
      when is_map(current) and is_integer(now_ms) and is_integer(ttl_ms) and is_list(models) and
             is_function(default_model_fun, 0) do
    id = Map.get(current, :model_id)

    case Map.get(current, :model_cache) do
      %{id: ^id, expires_at: expires_at, model: %Model{} = model} when expires_at > now_ms ->
        {model, current}

      _stale ->
        model = Catalog.fetch(models, id) || default_model_fun.()

        {model,
         %{
           current
           | model_cache: %{id: id, expires_at: now_ms + ttl_ms, model: model}
         }}
    end
  end

  @spec auth_label(Model.t() | nil) :: auth_label()
  def auth_label(%Model{status: :ready, label: label}), do: {"model: #{label}", :ok}

  def auth_label(%Model{status: {:needs_auth, hint}, label: label}),
    do: {"model: #{label}  #{hint}", :dim}

  def auth_label(_model), do: {"no model  -  /model", :dim}

  @doc "Provider/model footer label with optional last-turn latency."
  @spec hud_status(Model.t(), String.t() | nil, non_neg_integer() | nil) :: String.t()
  def hud_status(%Model{} = model, provider_model_slug, last_turn_ms) do
    label = hud_label(model, provider_model_slug)

    case last_turn_ms do
      ms when is_integer(ms) -> "#{label} · #{format_latency(ms)}"
      _none -> label
    end
  end

  @spec hud_label(Model.t(), String.t() | nil) :: String.t()
  def hud_label(%Model{label: label}, slug) when is_binary(slug) and slug != "",
    do: "provider: #{label}  model: #{slug}"

  def hud_label(%Model{label: label}, _slug), do: "provider: #{label}"

  defp format_latency(ms) when ms < 1_000, do: "#{ms}ms"
  defp format_latency(ms), do: "#{Float.round(ms / 1_000, 1)}s"
end
