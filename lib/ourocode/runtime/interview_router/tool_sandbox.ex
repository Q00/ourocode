defmodule Ourocode.Runtime.InterviewRouter.ToolSandbox do
  @moduledoc false

  @max_read_bytes 32_768
  @max_glob_hits 100
  @max_grep_bytes 8_192
  @grep_timeout_ms 5_000

  @spec run(atom(), String.t(), Path.t()) :: {String.t(), String.t()}
  def run(:read, rel, root) do
    case safe_path(rel, root) do
      {:ok, abs} ->
        case File.read(abs) do
          {:ok, bin} -> {"READ #{rel}", cap_middle(bin, @max_read_bytes)}
          {:error, reason} -> {"READ #{rel}", "error: #{:file.format_error(reason)}"}
        end

      {:error, why} ->
        {"READ #{rel}", "rejected: #{why}"}
    end
  end

  def run(:glob, pat, root) do
    case safe_relative?(pat) do
      :ok ->
        hits =
          root
          |> wildcard_path(pat)
          |> Path.wildcard()
          |> Enum.map(&relative_path(&1, root))
          |> Enum.take(@max_glob_hits)

        body = if hits == [], do: "(no matches)", else: Enum.join(hits, "\n")
        {"GLOB #{pat}", body}

      {:error, why} ->
        {"GLOB #{pat}", "rejected: #{why}"}
    end
  end

  def run(:grep, arg, root) do
    {pattern, glob} = split_grep_arg(arg)

    cond do
      pattern == "" ->
        {"GREP #{arg}", "rejected: empty pattern"}

      glob != nil and match?({:error, _}, safe_relative?(glob)) ->
        {"GREP #{arg}", "rejected: unsafe glob"}

      true ->
        {"GREP #{arg}", bounded_grep(pattern, glob, root)}
    end
  end

  def run(_tool, arg, _root), do: {"UNKNOWN #{inspect(arg)}", "rejected: unknown tool"}

  defp bounded_grep(pattern, glob, root) do
    task = Task.async(fn -> elixir_grep(pattern, glob, root) end)

    case Task.yield(task, @grep_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, out} ->
        if String.trim(out) == "", do: "(no matches)", else: cap_bytes(out, @max_grep_bytes)

      _timeout_or_crash ->
        "error: grep timed out"
    end
  end

  defp elixir_grep(pattern, glob, root) do
    matcher = grep_matcher(pattern)

    root
    |> grep_files(glob)
    |> Enum.flat_map(&grep_file(&1, root, matcher))
    |> Enum.join("\n")
  end

  defp grep_matcher(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> &Regex.match?(regex, &1)
      {:error, _reason} -> &String.contains?(&1, pattern)
    end
  end

  defp grep_files(root, nil) do
    root
    |> wildcard_path("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
  end

  defp grep_files(root, glob) do
    if String.contains?(glob, "/") do
      root
      |> wildcard_path(glob)
      |> Path.wildcard()
    else
      root
      |> wildcard_path("**/" <> glob)
      |> Path.wildcard()
    end
    |> Enum.filter(&File.regular?/1)
  end

  defp grep_file(path, root, matcher) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _index} -> matcher.(line) end)
        |> Enum.map(fn {line, index} -> "#{relative_path(path, root)}:#{index}:#{line}" end)

      {:error, _reason} ->
        []
    end
  end

  defp split_grep_arg(arg) do
    case String.split(String.trim(arg), ~r/\s+/, parts: 2) do
      [pattern] -> {pattern, nil}
      [pattern, glob] -> {pattern, String.trim(glob)}
      _none -> {"", nil}
    end
  end

  # Default-deny, resolve-then-contain: reject hostile literals before
  # resolving, then check containment of the resolved path. This closes the
  # TOCTOU/symlink-escape hole `Path.expand` alone leaves open: a link inside
  # the project pointing out would otherwise pass a pure string-prefix check.
  defp safe_path(rel, root) do
    with :ok <- safe_relative?(rel) do
      root = Path.expand(root)
      abs = Path.expand(rel, root)

      cond do
        not contained?(abs, root) -> {:error, "path escapes project root"}
        symlink_on_path?(rel, root) -> {:error, "symlinked path not allowed in sandbox"}
        true -> {:ok, abs}
      end
    end
  end

  defp contained?(abs, root), do: abs == root or String.starts_with?(abs, root <> "/")

  # Walk only the `rel` portion under `root`; if any existing component is a
  # symlink, reject. A read-only interview sandbox never needs to follow
  # links, so "no symlinks at all below root" is a stronger, simpler floor
  # than realpath-then-contain (and root's own ancestors stay out of scope).
  defp symlink_on_path?(rel, root) do
    rel
    |> Path.split()
    |> Enum.reduce_while(root, fn part, acc ->
      next = Path.join(acc, part)

      case :file.read_link(next) do
        {:ok, _target} -> {:halt, :symlink}
        _not_a_link -> {:cont, next}
      end
    end)
    |> Kernel.==(:symlink)
  end

  defp safe_relative?(path) when is_binary(path) do
    cond do
      path == "" -> {:error, "empty path"}
      String.contains?(path, <<0>>) -> {:error, "null byte"}
      String.starts_with?(path, "/") -> {:error, "absolute path"}
      String.starts_with?(path, "~") -> {:error, "home expansion"}
      String.contains?(path, ["$", "`"]) -> {:error, "shell expansion"}
      String.starts_with?(path, ["%", "="]) -> {:error, "shell expansion"}
      String.contains?(path, "\\") -> {:error, "backslash/UNC path"}
      ".." in Path.split(path) -> {:error, "parent escape"}
      true -> :ok
    end
  end

  defp safe_relative?(_path), do: {:error, "invalid path"}

  defp wildcard_path(root, pattern) do
    root
    |> Path.join(pattern)
    |> String.replace("\\", "/")
  end

  defp relative_path(path, root) do
    path
    |> Path.relative_to(root)
    |> String.replace("\\", "/")
  end

  defp cap_bytes(bin, limit) when byte_size(bin) <= limit, do: bin

  defp cap_bytes(bin, limit) do
    utf8_prefix(bin, limit) <> "\n...[truncated at #{limit} bytes]"
  end

  # Keep the head AND the tail of an oversized file instead of head-only:
  # imports/attributes live at the top, but what a follow-up question needs
  # (main clauses, exports, config blocks) is often at the bottom.
  defp cap_middle(bin, limit) when byte_size(bin) <= limit, do: bin

  defp cap_middle(bin, limit) do
    head = utf8_prefix(bin, div(limit * 3, 4))
    tail = utf8_suffix(bin, limit - div(limit * 3, 4))
    elided = byte_size(bin) - byte_size(head) - byte_size(tail)
    head <> "\n...[#{elided} bytes elided]...\n" <> tail
  end

  # Byte-limit cuts must not split a multibyte character: the observation is
  # embedded in a prompt string, so it has to stay valid UTF-8. A cut lands
  # at most 3 bytes inside a sequence; after that the content was not UTF-8
  # to begin with and is returned as-is (same as an undersized binary read).
  defp utf8_prefix(bin, limit) do
    trim_invalid(binary_part(bin, 0, limit), :back, 3)
  end

  defp utf8_suffix(bin, limit) do
    trim_invalid(binary_part(bin, byte_size(bin) - limit, limit), :front, 3)
  end

  defp trim_invalid(part, _side, attempts_left)
       when attempts_left < 0 or byte_size(part) == 0,
       do: part

  defp trim_invalid(part, side, attempts_left) do
    if String.valid?(part) do
      part
    else
      case side do
        :back -> trim_invalid(binary_part(part, 0, byte_size(part) - 1), side, attempts_left - 1)
        :front -> trim_invalid(binary_part(part, 1, byte_size(part) - 1), side, attempts_left - 1)
      end
    end
  end
end
