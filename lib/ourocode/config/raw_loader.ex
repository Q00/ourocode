defmodule Ourocode.Config.RawLoader do
  @moduledoc """
  Project config discovery, parsing, merging, and runtime override projection.
  """

  alias Ourocode.Config.RawConfig
  alias Ourocode.Config.SimpleParser

  @supported_config_candidates [
    "ourocode.json",
    "ourocode.yaml",
    "ourocode.yml",
    "ourocode.toml",
    ".ourocode.json",
    ".ourocode.yaml",
    ".ourocode.yml",
    ".ourocode.toml",
    Path.join([".ourocode", "config.json"]),
    Path.join([".ourocode", "config.yaml"]),
    Path.join([".ourocode", "config.yml"]),
    Path.join([".ourocode", "config.toml"])
  ]

  @runtime_override_keys [
    :parallel_child_count,
    :repeat_count,
    :stream_mailbox_capacity,
    :stream_mailbox_overflow_path,
    :stream_mailbox_backpressure_threshold,
    :stream_mailbox_backpressure_behavior,
    :stream_mailbox_backpressure_delay_ms,
    :allowed_memory_growth_mb,
    :stale_cleanup_timeout_ms,
    :operation_timeout_ms,
    :stream_subscription_cleanup_timeout_ms,
    :pane_state_retention_ms
  ]

  @runtime_override_key_names Map.new(@runtime_override_keys, &{Atom.to_string(&1), &1})

  @spec supported_config_candidates() :: [Path.t()]
  def supported_config_candidates, do: @supported_config_candidates

  @spec discover_config_files(Path.t()) :: [Path.t()]
  def discover_config_files(project_dir) when is_binary(project_dir) do
    root_dir = absolute_path(project_dir)

    @supported_config_candidates
    |> Enum.map(&Path.join(root_dir, &1))
    |> Enum.filter(&File.regular?/1)
  end

  @spec load(Path.t()) :: {:ok, RawConfig.t()} | {:error, Ourocode.Config.raw_config_error()}
  def load(project_dir) when is_binary(project_dir) do
    root_dir = absolute_path(project_dir)

    Enum.reduce_while(discover_config_files(root_dir), {:ok, []}, fn path, {:ok, entries} ->
      case parse_config_file(path, root_dir) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} ->
        files = Enum.reverse(entries)
        data = Enum.reduce(files, %{}, fn entry, acc -> deep_merge(acc, entry.data) end)
        {:ok, %RawConfig{root_dir: root_dir, files: files, data: data}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec parse_config_file(Path.t(), Path.t() | nil) ::
          {:ok, RawConfig.file_entry()} | {:error, Ourocode.Config.raw_config_error()}
  def parse_config_file(path, root_dir \\ nil) when is_binary(path) do
    expanded_path = absolute_path(path)

    root_dir =
      if is_binary(root_dir), do: absolute_path(root_dir), else: Path.dirname(expanded_path)

    with {:ok, format} <- config_format(expanded_path),
         {:ok, contents} <- read_config_file(expanded_path),
         {:ok, data} <- parse_config_contents(contents, format, expanded_path),
         {:ok, map} <- require_config_map(data, expanded_path) do
      {:ok,
       %{
         path: expanded_path,
         relative_path: Path.relative_to(expanded_path, root_dir),
         format: format,
         data: normalize_raw_config(map)
       }}
    end
  end

  @spec runtime_overrides_from_raw(map()) ::
          {:ok, map()} | {:error, {:config_section_must_be_map, String.t(), term()}}
  def runtime_overrides_from_raw(data) when is_map(data) do
    with {:ok, runtime} <- optional_config_section(data, "runtime"),
         {:ok, cleanup_policy} <- optional_config_section(runtime, "cleanup_policy") do
      runtime
      |> Map.drop(["cleanup_policy"])
      |> override_keys_from_string_map()
      |> Map.merge(override_keys_from_string_map(cleanup_policy))
      |> then(&{:ok, &1})
    end
  end

  defp absolute_path(path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.expand(path)
    end
  end

  defp config_format(path) do
    case path |> Path.basename() |> String.downcase() do
      name when name in ["ourocode.json", ".ourocode.json", "config.json"] ->
        {:ok, :json}

      name when name in ["ourocode.yaml", "ourocode.yml", ".ourocode.yaml", ".ourocode.yml"] ->
        {:ok, :yaml}

      name when name in ["config.yaml", "config.yml"] ->
        {:ok, :yaml}

      name when name in ["ourocode.toml", ".ourocode.toml", "config.toml"] ->
        {:ok, :toml}

      _name ->
        {:error, {:unsupported_config_format, path}}
    end
  end

  defp read_config_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:cannot_read_config_file, path, reason}}
    end
  end

  defp parse_config_contents(contents, format, path) when format in [:json, :yaml, :toml] do
    SimpleParser.parse(contents, format, path)
  end

  defp require_config_map(data, _path) when is_map(data), do: {:ok, data}
  defp require_config_map(_data, path), do: {:error, {:config_file_must_be_map, path}}

  defp optional_config_section(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      :error -> {:ok, %{}}
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, invalid} -> {:error, {:config_section_must_be_map, key, invalid}}
    end
  end

  defp override_keys_from_string_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      case runtime_override_key(key) do
        {:ok, override_key} -> Map.put(acc, override_key, value)
        :error -> acc
      end
    end)
  end

  defp runtime_override_key(key) when is_binary(key) do
    key
    |> String.replace("-", "_")
    |> then(&Map.fetch(@runtime_override_key_names, &1))
  end

  defp runtime_override_key(key) when key in @runtime_override_keys, do: {:ok, key}
  defp runtime_override_key(_key), do: :error

  defp normalize_raw_config(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested_value} ->
      {normalize_raw_key(key), normalize_raw_config(nested_value)}
    end)
    |> Map.new()
  end

  defp normalize_raw_config(value) when is_list(value),
    do: Enum.map(value, &normalize_raw_config/1)

  defp normalize_raw_config(value), do: value

  defp normalize_raw_key(key) when is_atom(key),
    do: key |> Atom.to_string() |> normalize_raw_key()

  defp normalize_raw_key(key) when is_binary(key) do
    key
    |> String.trim()
    |> String.replace("-", "_")
  end

  defp normalize_raw_key(key), do: key |> to_string() |> normalize_raw_key()

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right
end
