defmodule Ourocode.Plugin.UserLevel.ArtifactWatcher do
  @moduledoc """
  Scans for artifact paths declared by a UserLevel plugin command after the
  plugin run completes.

  Only the globs published by the plugin's own
  `CommandCapability.expected_artifacts` list are considered. `ourocode`
  never hardcodes plugin-internal storage paths.

  This module is pure and has no GenServer / process state. It is invoked
  by `Ourocode.Runtime.UserLevelPluginInvocation` right after the
  external command runner returns.
  """

  alias Ourocode.Plugin.UserLevel.Capability.Command, as: CommandCapability

  @type artifact :: %{
          required(:kind) => :seed | :handoff | :report | :log | :other,
          required(:path) => String.t(),
          required(:glob) => String.t(),
          optional(:size) => non_neg_integer(),
          optional(:digest) => String.t(),
          optional(:generated_at) => DateTime.t()
        }

  @doc """
  Returns the matched artifact list for the given command capability and cwd.

  When `:lstat?` is `true` (default), each matched path gets size, digest, and
  generated_at fields populated from the local file system. Pass `:lstat?:
  false` to keep the scan filesystem-free (useful in tests where the file
  doesn't need to exist).
  """
  @spec scan(CommandCapability.t(), Path.t(), keyword()) :: [artifact()]
  def scan(%CommandCapability{expected_artifacts: globs}, cwd, opts \\ [])
      when is_binary(cwd) and is_list(globs) do
    lstat? = Keyword.get(opts, :lstat?, true)

    globs
    |> Enum.flat_map(fn glob -> expand_glob(glob, cwd, lstat?) end)
    |> Enum.uniq_by(& &1.path)
  end

  defp expand_glob(glob, cwd, lstat?) do
    full_glob = Path.expand(glob, cwd)

    full_glob
    |> Path.wildcard(match_dot: false)
    |> Enum.map(fn path -> build_artifact(path, glob, lstat?) end)
  end

  defp build_artifact(path, glob, lstat?) do
    base = %{
      kind: classify(path),
      path: path,
      glob: glob
    }

    if lstat? do
      add_lstat(base, path)
    else
      base
    end
  end

  defp add_lstat(artifact, path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{size: size, mtime: mtime}} ->
        artifact
        |> Map.put(:size, size)
        |> Map.put(:generated_at, posix_to_datetime(mtime))
        |> maybe_digest(path)

      {:error, _reason} ->
        artifact
    end
  end

  defp posix_to_datetime(seconds) when is_integer(seconds) do
    DateTime.from_unix!(seconds)
  end

  defp maybe_digest(artifact, path) do
    # Only digest small text artifacts (Seed/handoff are markdown; size cap is
    # to avoid hashing arbitrary plugin-emitted blobs).
    case artifact do
      %{size: size} when is_integer(size) and size <= 1_048_576 ->
        case File.read(path) do
          {:ok, content} ->
            digest = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
            Map.put(artifact, :digest, "sha256:" <> digest)

          {:error, _reason} ->
            artifact
        end

      _other ->
        artifact
    end
  end

  defp classify(path) do
    basename = path |> Path.basename() |> String.downcase()

    cond do
      basename == "seed.md" -> :seed
      basename == "handoff.md" -> :handoff
      basename in ["report.md", "evidence.json"] -> :report
      String.ends_with?(basename, ".log") -> :log
      String.ends_with?(basename, ".jsonl") and String.contains?(basename, "audit") -> :log
      true -> :other
    end
  end
end
