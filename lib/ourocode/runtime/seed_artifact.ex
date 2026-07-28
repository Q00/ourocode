defmodule Ourocode.Runtime.SeedArtifact do
  @moduledoc """
  Captures generated Seed YAML artifacts from Ouroboros workflow responses.
  """

  alias Ourocode.Runtime.InterviewResponse

  @seed_marker "--- Seed YAML ---"
  @seed_id_re ~r/^\s*seed_id:\s*([A-Za-z0-9_.-]+)/m
  @metadata_seed_id_re ~r/^\s*metadata:\s*\n(?:\s+.+\n)*?\s+seed_id:\s*([A-Za-z0-9_.-]+)/m

  @type artifact :: %{
          required(:seed_id) => String.t(),
          required(:path) => String.t()
        }

  @spec capture(term(), term(), term()) :: {:ok, artifact()} | :ignore | {:error, term()}
  def capture(text, cwd, meta) when is_binary(text) and is_binary(cwd) and is_map(meta) do
    with {:ok, seed_yaml} <- extract_yaml(text),
         seed_id when is_binary(seed_id) and seed_id != "" <- seed_id(meta, seed_yaml),
         {:ok, path} <- write(cwd, seed_id, seed_yaml) do
      {:ok, %{seed_id: seed_id, path: path}}
    else
      :ignore -> :ignore
      nil -> :ignore
      "" -> :ignore
      {:error, reason} -> {:error, reason}
      _other -> :ignore
    end
  end

  def capture(_text, _cwd, _meta), do: :ignore

  @spec extract_yaml(String.t()) :: {:ok, String.t()} | :ignore
  def extract_yaml(text) when is_binary(text) do
    case String.split(text, @seed_marker, parts: 2) do
      [_before, yaml] ->
        yaml =
          yaml
          |> String.replace("\r\n", "\n")
          |> String.trim()

        if yaml == "", do: :ignore, else: {:ok, yaml}

      _other ->
        :ignore
    end
  end

  @spec seed_id(map(), String.t()) :: String.t() | nil
  def seed_id(meta, seed_yaml) when is_map(meta) and is_binary(seed_yaml) do
    InterviewResponse.meta_value(meta, "seed_id") || seed_id_from_yaml(seed_yaml)
  end

  def seed_id(_meta, _seed_yaml), do: nil

  @spec write(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def write(cwd, seed_id, seed_yaml)
      when is_binary(cwd) and is_binary(seed_id) and is_binary(seed_yaml) do
    path = Path.join(cwd, seed_id <> ".yaml")

    case File.write(path, seed_yaml <> "\n") do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp seed_id_from_yaml(seed_yaml) do
    case Regex.run(@seed_id_re, seed_yaml) || Regex.run(@metadata_seed_id_re, seed_yaml) do
      [_, id] -> id
      _none -> nil
    end
  end
end
