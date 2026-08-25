defmodule Ourocode.Terminal.PromptStore do
  @moduledoc """
  Small JSONL-backed prompt history/draft store for the raw TUI.

  The TUI treats persistence as best-effort UX state. Store failures never
  block prompt input.
  """

  @history_file "prompt_history.jsonl"
  @draft_file "prompt_draft.txt"
  @limit 50
  @stored_entry_limit 1_000
  @max_history_bytes 262_144

  @spec load_history(keyword()) :: [String.t()]
  def load_history(opts \\ []) do
    opts
    |> read_history_entries()
    |> Enum.uniq()
    |> Enum.take(@limit)
  end

  @spec command_usage(keyword()) :: %{String.t() => non_neg_integer()}
  def command_usage(opts \\ []) do
    opts
    |> read_history_entries()
    |> Enum.reduce(%{}, fn line, acc ->
      case command_key(line) do
        nil -> acc
        key -> Map.update(acc, key, 1, &(&1 + 1))
      end
    end)
  end

  @spec append_history(String.t(), keyword()) :: :ok
  def append_history(line, opts \\ []) when is_binary(line) do
    line = String.trim(line)

    if line == "" do
      :ok
    else
      path = history_path(opts)
      _ = File.mkdir_p(Path.dirname(path))

      encoded = "v1\t" <> Base.encode64(line)
      _ = File.write(path, encoded <> "\n", [:append])
      compact_history(path)

      :ok
    end
  rescue
    _exception -> :ok
  end

  @spec load_draft(keyword()) :: String.t()
  def load_draft(opts \\ []) do
    opts
    |> draft_path()
    |> File.read()
    |> case do
      {:ok, text} -> String.trim_trailing(text)
      _error -> ""
    end
  end

  @spec save_draft(String.t(), keyword()) :: :ok
  def save_draft(text, opts \\ []) when is_binary(text) do
    path = draft_path(opts)
    _ = File.mkdir_p(Path.dirname(path))
    _ = File.write(path, text)
    :ok
  rescue
    _exception -> :ok
  end

  @spec clear_draft(keyword()) :: :ok
  def clear_draft(opts \\ []) do
    _ = File.rm(draft_path(opts))
    :ok
  rescue
    _exception -> :ok
  end

  defp decode_history_line(line) do
    case String.split(line, "\t", parts: 2) do
      ["v1", encoded] ->
        case Base.decode64(encoded) do
          {:ok, text} when text != "" -> [text]
          _other -> []
        end

      _other ->
        []
    end
  end

  defp read_history_entries(opts) do
    path = history_path(opts)

    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 ->
        offset = max(size - @max_history_bytes, 0)

        case :file.open(String.to_charlist(path), [:read, :binary]) do
          {:ok, file} ->
            result =
              case :file.pread(file, offset, size - offset) do
                {:ok, body} -> decode_history_tail(body, offset > 0)
                _error -> []
              end

            :file.close(file)
            result

          _error ->
            []
        end

      _error ->
        []
    end
  end

  defp decode_history_tail(body, truncated?) do
    lines = String.split(body, "\n", trim: true)
    lines = if truncated?, do: Enum.drop(lines, 1), else: lines

    lines
    |> Enum.reverse()
    |> Enum.flat_map(&decode_history_line/1)
    |> Enum.take(@stored_entry_limit)
  end

  defp compact_history(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_history_bytes ->
        body =
          path
          |> then(&read_history_entries(state_dir: Path.dirname(&1)))
          |> Enum.reverse()
          |> Enum.map_join("", fn line -> "v1\t" <> Base.encode64(line) <> "\n" end)

        File.write(path, body)

      _other ->
        :ok
    end
  rescue
    _exception -> :ok
  end

  defp command_key(line) do
    line
    |> String.trim()
    |> String.split(~r/\s+/, parts: 3)
    |> case do
      ["/" <> cmd | _rest] -> "/" <> cmd
      ["ooo", sub | _rest] -> "ooo " <> sub
      ["ooo"] -> "ooo"
      _other -> nil
    end
  end

  defp history_path(opts), do: Path.join(state_dir(opts), @history_file)
  defp draft_path(opts), do: Path.join(state_dir(opts), @draft_file)

  defp state_dir(opts) do
    Keyword.get(opts, :state_dir) ||
      System.get_env("OUROCODE_STATE_DIR") ||
      Path.join(System.user_home!(), ".ourocode")
  end
end
