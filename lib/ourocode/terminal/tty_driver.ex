defmodule Ourocode.Terminal.TtyDriver do
  @moduledoc """
  Native tty helper boundary for the interactive TUI.
  """

  @poll_ms 500
  @helper_osc_prefix "\e]777;ourocode-"
  @helper_osc_resize_prefix "\e]777;ourocode-resize="
  @helper_osc_redraw "\e]777;ourocode-control=redraw\a"
  @bracketed_paste_start "\e[200~"
  @bracketed_paste_end "\e[201~"

  @doc "Absolute path of the built tty helper, or nil if it is not present."
  @spec helper_path() :: String.t() | nil
  def helper_path do
    cwd = File.cwd!()

    [
      System.get_env("OUROCODE_TTY"),
      Path.join(cwd, "bin/ourocode_tty.exe"),
      Path.join(cwd, "bin/ourocode_tty"),
      Path.join(cwd, "rust/ourocode_ipc/target/release/ourocode_tty.exe"),
      Path.join(cwd, "rust/ourocode_ipc/target/release/ourocode_tty")
    ]
    |> helper_path()
  end

  @doc false
  @spec helper_path([String.t() | nil]) :: String.t() | nil
  def helper_path(paths) when is_list(paths) do
    Enum.find(paths, fn path -> is_binary(path) and File.exists?(path) end)
  end

  @spec start() :: {:ok, port(), {pos_integer(), pos_integer()}, binary()} | :error
  def start do
    case helper_path() do
      nil ->
        :error

      path ->
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(path)},
            port_options(:os.type())
          )

        case read_header(port, "") do
          {:ok, cols, rows, rest} ->
            write(port, enter_sequence())
            {:ok, port, {cols, rows}, rest}

          :error ->
            safe_close(port)
            :error
        end
    end
  end

  @spec stop(port() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(port) do
    write(port, exit_sequence())
    safe_close(port)
  end

  @spec write(port() | nil, iodata()) :: :ok
  def write(nil, _iodata), do: :ok

  def write(port, iodata) when is_port(port) do
    Port.command(port, IO.iodata_to_binary(iodata))
    :ok
  rescue
    _exception -> :ok
  end

  @spec next_chunk(port() | nil, non_neg_integer()) ::
          {:ok, binary()}
          | {:ok, binary(), binary()}
          | {:resize, {pos_integer(), pos_integer()}}
          | {:resize, {pos_integer(), pos_integer()}, binary()}
          | {:control, :redraw}
          | {:control, :redraw, binary()}
          | {:ignore, binary()}
          | {:file_cache_ready, [String.t()]}
          | :tick
          | :eof
  def next_chunk(port, poll_ms \\ @poll_ms) do
    receive do
      {^port, {:data, data}} when is_binary(data) ->
        data
        |> decode_chunk()
        |> next_chunk_reply()

      {^port, {:exit_status, _status}} ->
        :eof

      {:file_cache_ready, files} when is_list(files) ->
        {:file_cache_ready, files}
    after
      poll_ms -> :tick
    end
  end

  @spec size({pos_integer(), pos_integer()}) :: {pos_integer(), pos_integer()}
  def size(fallback) do
    case {:io.columns(), :io.rows()} do
      {{:ok, cols}, {:ok, rows}} when cols > 0 and rows > 0 -> {cols, rows}
      _other -> fallback
    end
  rescue
    _exception -> fallback
  end

  @spec tty?() :: boolean()
  def tty? do
    System.get_env("OUROCODE_FORCE_TTY") == "1" or match?({:ok, _}, :io.columns())
  end

  @doc false
  @spec port_options(:os.type()) :: [:binary | :exit_status | :nouse_stdio | :hide]
  def port_options({:win32, _}), do: [:binary, :exit_status]
  def port_options(_os_type), do: [:binary, :exit_status, :nouse_stdio, :hide]

  @doc false
  def enter_sequence, do: "\e[?1049h\e[?1006h\e[?1003h\e[?25l\e[2J\e[H"

  @doc false
  def exit_sequence, do: "\e[?1003l\e[?1006l\e[?25h\e[?1049l"

  @doc false
  @spec parse_header(binary()) ::
          {:ok, pos_integer(), pos_integer(), binary()} | :partial | :error
  def parse_header(data) when is_binary(data) do
    case :binary.split(data, "\n") do
      [line, rest] ->
        case line |> String.split() |> Enum.map(&Integer.parse/1) do
          [{cols, _}, {rows, _}] when cols > 0 and rows > 0 -> {:ok, cols, rows, rest}
          _invalid -> :error
        end

      [_partial] ->
        :partial
    end
  end

  defp read_header(port, acc) do
    receive do
      {^port, {:data, data}} ->
        case parse_header(acc <> data) do
          :partial -> read_header(port, acc <> data)
          parsed -> parsed
        end

      {^port, {:exit_status, _status}} ->
        :error
    after
      5_000 -> :error
    end
  end

  @doc false
  @spec decode_chunk(binary()) ::
          {:ok, binary(), binary()}
          | {:resize, {pos_integer(), pos_integer()}, binary()}
          | {:control, :redraw, binary()}
          | {:ignore, binary()}
  def decode_chunk(data) when is_binary(data) do
    case helper_frame_bounds(data) do
      nil ->
        {:ok, data, ""}

      {0, frame_size} ->
        frame = binary_part(data, 0, frame_size)
        rest = binary_part(data, frame_size, byte_size(data) - frame_size)
        decode_helper_frame(frame, rest)

      {start, _frame_size} ->
        raw = binary_part(data, 0, start)
        rest = binary_part(data, start, byte_size(data) - start)
        {:ok, raw, rest}
    end
  end

  defp next_chunk_reply({:ok, data, ""}), do: {:ok, data}
  defp next_chunk_reply({:resize, size, ""}), do: {:resize, size}
  defp next_chunk_reply({:control, :redraw, ""}), do: {:control, :redraw}
  defp next_chunk_reply({:ignore, ""}), do: :tick
  defp next_chunk_reply(other), do: other

  defp decode_helper_frame(@helper_osc_redraw, rest), do: {:control, :redraw, rest}

  defp decode_helper_frame(@helper_osc_resize_prefix <> rest = frame, remaining) do
    with true <- String.ends_with?(rest, "\a"),
         value <- binary_part(rest, 0, byte_size(rest) - 1),
         [cols_text, rows_text] <- String.split(value, "x", parts: 2),
         {cols, ""} when cols > 0 <- Integer.parse(cols_text),
         {rows, ""} when rows > 0 <- Integer.parse(rows_text) do
      {:resize, {cols, rows}, remaining}
    else
      _invalid ->
        if helper_control_frame?(frame), do: {:ignore, remaining}, else: {:ok, frame, remaining}
    end
  end

  defp decode_helper_frame(frame, rest) do
    if helper_control_frame?(frame), do: {:ignore, rest}, else: {:ok, frame, rest}
  end

  defp helper_control_frame?(data) do
    String.starts_with?(data, @helper_osc_prefix) and String.ends_with?(data, "\a")
  end

  defp helper_frame_bounds(data), do: helper_frame_bounds(data, 0)

  defp helper_frame_bounds(data, offset) when offset >= byte_size(data), do: nil

  defp helper_frame_bounds(data, offset) do
    case next_helper_or_paste(data, offset) do
      nil ->
        nil

      {:helper, index} ->
        case match_from(data, "\a", index) do
          {bel_index, 1} -> {index, bel_index - index + 1}
          :nomatch -> nil
        end

      {:paste, index} ->
        paste_content_index = index + byte_size(@bracketed_paste_start)

        case match_from(data, @bracketed_paste_end, paste_content_index) do
          {paste_end_index, paste_end_size} ->
            helper_frame_bounds(data, paste_end_index + paste_end_size)

          :nomatch ->
            nil
        end
    end
  end

  defp next_helper_or_paste(data, offset) do
    match =
      [
        helper: match_from(data, @helper_osc_prefix, offset),
        paste: match_from(data, @bracketed_paste_start, offset)
      ]
      |> Enum.reject(fn {_kind, match} -> match == :nomatch end)
      |> Enum.min_by(fn {_kind, {index, _size}} -> index end, fn -> nil end)

    case match do
      nil -> nil
      {kind, {index, _size}} -> {kind, index}
    end
  end

  defp match_from(data, pattern, offset) do
    if offset >= byte_size(data) do
      :nomatch
    else
      :binary.match(data, pattern, scope: {offset, byte_size(data) - offset})
    end
  end

  defp safe_close(port) do
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    _exception -> :ok
  end
end
