defmodule Ourocode.Plugin.PathPolicy do
  @moduledoc """
  Validates plugin paths against configured allowed roots.

  The policy resolves both plugin paths and allowed roots before comparison,
  including existing symlinked path segments, so relative plugin paths can be
  accepted without relying on string-prefix checks.
  """

  @app :ourocode

  @type validation_error :: :plugin_path_not_allowed | :invalid_allowed_plugin_roots

  @doc """
  Expands and validates a plugin path against configured allowed roots.

  Options:

    * `:allowed_roots` - allowed plugin root directories. Defaults to
      `Application.get_env(:ourocode, :plugin_allowed_roots, [])`.
    * `:base_dir` - base directory used to expand relative plugin paths and
      relative allowed roots. Defaults to the current working directory.
  """
  @spec validate(Path.t(), keyword()) :: {:ok, String.t()} | {:error, validation_error()}
  def validate(plugin_path, opts \\ []) when is_binary(plugin_path) and is_list(opts) do
    base_dir = Keyword.get(opts, :base_dir, File.cwd!())
    expanded_path = expand(plugin_path, base_dir)

    with {:ok, allowed_roots} <- allowed_roots(opts),
         true <- path_allowed?(expanded_path, allowed_roots, base_dir) do
      {:ok, expanded_path}
    else
      false -> {:error, :plugin_path_not_allowed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp allowed_roots(opts) do
    roots =
      Keyword.get(opts, :allowed_roots, Application.get_env(@app, :plugin_allowed_roots, []))

    if is_list(roots) and Enum.all?(roots, &is_binary/1) do
      {:ok, roots}
    else
      {:error, :invalid_allowed_plugin_roots}
    end
  end

  defp path_allowed?(_plugin_path, [], _base_dir), do: false

  defp path_allowed?(plugin_path, allowed_roots, base_dir) do
    canonical_path = canonical_path(plugin_path)

    Enum.any?(allowed_roots, fn root ->
      path_under_root?(canonical_path, canonical_path(expand(root, base_dir)))
    end)
  end

  defp path_under_root?(path, root) do
    path_parts = Path.split(path)
    root_parts = Path.split(root)

    length(path_parts) >= length(root_parts) and
      Enum.take(path_parts, length(root_parts)) == root_parts
  end

  defp expand(path, base_dir) do
    Path.expand(path, base_dir)
  end

  defp canonical_path(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> resolve_existing_segments()
  end

  defp resolve_existing_segments([]), do: ""
  defp resolve_existing_segments([root | parts]), do: resolve_existing_segments(root, parts)

  defp resolve_existing_segments(path, []), do: path

  defp resolve_existing_segments(path, [part | remaining_parts]) do
    candidate = Path.join(path, part)

    if File.exists?(candidate) do
      candidate
      |> resolve_link()
      |> resolve_existing_segments(remaining_parts)
    else
      Path.join([candidate | remaining_parts])
    end
  end

  defp resolve_link(path) do
    charlist_path = String.to_charlist(path)

    with {:ok,
          {:file_info, _size, :symlink, _access, _atime, _mtime, _ctime, _mode, _links,
           _major_device, _minor_device, _inode, _uid, _gid}} <-
           :file.read_link_info(charlist_path),
         {:ok, target} <- :file.read_link(charlist_path) do
      target
      |> List.to_string()
      |> Path.expand(Path.dirname(path))
    else
      _ -> path
    end
  end
end
