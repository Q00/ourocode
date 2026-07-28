defmodule Ourocode.Terminal.TuiDriverSession do
  @moduledoc """
  State-bound native TTY helper session operations for the TUI.

  `TtyDriver` owns the low-level Port protocol. This module applies that
  protocol to the mutable TUI state so `Tui` can stay focused on input and
  rendering flow.
  """

  alias Ourocode.Terminal.{TtyDriver, TuiState}

  @poll_ms 500

  @doc "Absolute path of the built tty helper, or nil if it is not present."
  @spec helper_path() :: String.t() | nil
  def helper_path, do: TtyDriver.helper_path()

  @spec start(pid()) :: :ok | :error
  def start(state) when is_pid(state) do
    case TtyDriver.start() do
      {:ok, port, size, rest} ->
        TuiState.put_port(state, port)
        TuiState.put_size(state, size)
        TuiState.put_inbuf(state, rest)
        :ok

      :error ->
        :error
    end
  end

  @spec stop(pid()) :: :ok
  def stop(state) when is_pid(state) do
    state
    |> TuiState.port()
    |> TtyDriver.stop()
  end

  @spec write(pid(), iodata()) :: :ok
  def write(state, iodata) when is_pid(state) do
    state
    |> TuiState.port()
    |> TtyDriver.write(iodata)
  end

  @spec next_chunk(pid(), non_neg_integer()) ::
          {:ok, binary()}
          | {:resize, {pos_integer(), pos_integer()}}
          | {:control, :redraw}
          | :tick
          | :eof
  def next_chunk(state, poll_ms \\ @poll_ms) when is_pid(state) do
    case TuiState.take_inbuf(state) do
      "" ->
        case TtyDriver.next_chunk(TuiState.port(state), poll_ms) do
          {:ok, raw, rest} ->
            TuiState.put_inbuf(state, rest)
            {:ok, raw}

          {:resize, size, rest} ->
            TuiState.put_inbuf(state, rest)
            TuiState.put_size(state, size)
            {:resize, size}

          {:resize, size} ->
            TuiState.put_size(state, size)
            {:resize, size}

          {:control, :redraw, rest} ->
            TuiState.put_inbuf(state, rest)
            {:control, :redraw}

          {:control, :redraw} ->
            {:control, :redraw}

          {:ignore, rest} ->
            TuiState.put_inbuf(state, rest)
            :tick

          {:file_cache_ready, files} ->
            TuiState.put_file_cache(state, files)
            :tick

          other ->
            other
        end

      buffered ->
        apply_decoded_chunk(state, TtyDriver.decode_chunk(buffered))
    end
  end

  defp apply_decoded_chunk(state, {:ok, raw, rest}) do
    TuiState.put_inbuf(state, rest)
    {:ok, raw}
  end

  defp apply_decoded_chunk(state, {:resize, size, rest}) do
    TuiState.put_inbuf(state, rest)
    TuiState.put_size(state, size)
    {:resize, size}
  end

  defp apply_decoded_chunk(state, {:control, :redraw, rest}) do
    TuiState.put_inbuf(state, rest)
    {:control, :redraw}
  end

  defp apply_decoded_chunk(state, {:ignore, rest}) do
    TuiState.put_inbuf(state, rest)
    :tick
  end

  @spec refresh_size(pid()) :: {pos_integer(), pos_integer()}
  def refresh_size(state) when is_pid(state) do
    size = TtyDriver.size(TuiState.size(state))
    TuiState.put_size(state, size)
    size
  end

  @doc false
  def enter_sequence, do: TtyDriver.enter_sequence()

  @doc false
  def exit_sequence, do: TtyDriver.exit_sequence()
end
