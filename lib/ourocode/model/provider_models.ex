defmodule Ourocode.Model.ProviderModels do
  @moduledoc """
  Provider-specific model slug catalog.

  Backend providers and provider model slugs are separate UI choices. This
  module keeps slug validation out of the backend discovery catalog.
  """

  @codex_model_slugs [
    %{provider_id: :codex, slug: "gpt-5.5", label: "gpt-5.5", default?: true},
    %{provider_id: :codex, slug: "gpt-5.3-codex", label: "gpt-5.3-codex", default?: false}
  ]

  @provider_model_slugs %{codex: @codex_model_slugs}

  @doc "Provider-specific model slugs available for a backend provider."
  @spec provider_model_slugs(atom()) :: [map()]
  def provider_model_slugs(provider_id) when is_atom(provider_id),
    do: Map.get(@provider_model_slugs, provider_id, [])

  def provider_model_slugs(_provider_id), do: []

  @doc "Built-in default model slug for a backend provider."
  @spec default_provider_model_slug(atom()) :: String.t() | nil
  def default_provider_model_slug(provider_id) when is_atom(provider_id) do
    provider_id
    |> provider_model_slugs()
    |> Enum.find(&Map.get(&1, :default?, false))
    |> case do
      %{slug: slug} -> slug
      nil -> nil
    end
  end

  def default_provider_model_slug(_provider_id), do: nil

  @doc "Looks up a provider-specific model slug after normalizing user input."
  @spec fetch_provider_model_slug(atom(), term()) :: map() | nil
  def fetch_provider_model_slug(provider_id, slug) when is_atom(provider_id) do
    with {:ok, normalized} <- normalize_provider_model_slug(slug) do
      Enum.find(provider_model_slugs(provider_id), &(&1.slug == normalized))
    else
      _error -> nil
    end
  end

  def fetch_provider_model_slug(_provider_id, _slug), do: nil

  @doc """
  Validates a provider-specific model slug.

  Built-in slugs must be present in `provider_model_slugs/1`. Tests and future
  provider migration paths may pass `allow_custom?: true` to store a nonblank
  slug without making it the global default or adding it to the catalog.
  """
  @spec validate_provider_model_slug(atom(), term(), keyword()) ::
          {:ok, String.t()}
          | {:error, :unknown_provider | :invalid_slug | :blank_slug | :unknown_slug}
  def validate_provider_model_slug(provider_id, slug, opts \\ [])

  def validate_provider_model_slug(provider_id, slug, opts) when is_atom(provider_id) do
    with {:provider, [_ | _]} <- {:provider, provider_model_slugs(provider_id)},
         {:ok, normalized} <- normalize_provider_model_slug(slug) do
      cond do
        fetch_provider_model_slug(provider_id, normalized) ->
          {:ok, normalized}

        Keyword.get(opts, :allow_custom?, false) ->
          {:ok, normalized}

        true ->
          {:error, :unknown_slug}
      end
    else
      {:provider, []} -> {:error, :unknown_provider}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_provider_model_slug(_provider_id, _slug, _opts), do: {:error, :unknown_provider}

  defp normalize_provider_model_slug(slug) when is_binary(slug) do
    case String.trim(slug) do
      "" -> {:error, :blank_slug}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_provider_model_slug(_slug), do: {:error, :invalid_slug}
end
