defmodule Ourocode.Terminal.KeyReader do
  @moduledoc """
  Pure raw-terminal byte/ANSI stream decoder.

  Raw mode delivers keystrokes as bytes (and multi-byte ANSI escape
  sequences) rather than cooked lines. This module converts an arbitrary
  byte buffer into ordered key events, returning any trailing bytes that
  form an incomplete escape or UTF-8 sequence so the caller can prepend
  them to the next read. It owns no IO and no process state, which keeps
  the terminal driver's input path fully unit-testable.
  """

  alias Ourocode.Terminal.{KeyEvent, KeySequence, KeyUtf8}

  @type key ::
          :enter
          | :backspace
          | :tab
          | :escape
          | :ctrl_c
          | :ctrl_a
          | :ctrl_b
          | :ctrl_d
          | :ctrl_e
          | :ctrl_f
          | :ctrl_g
          | :ctrl_k
          | :ctrl_n
          | :ctrl_p
          | :ctrl_r
          | :ctrl_u
          | :ctrl_w
          | :ctrl_y
          | :alt_b
          | :alt_d
          | :alt_f
          | :alt_y
          | :cmd_backspace
          | :ctrl_backspace
          | :cmd_plus
          | :cmd_minus
          | :up
          | :down
          | :left
          | :right
          | :home
          | :end
          | :delete
          | :page_up
          | :page_down
          | :paste
          | :char

  @type event :: %{
          required(:type) => :key,
          required(:key) => key(),
          required(:char) => String.t() | nil
        }

  @doc """
  Decodes a raw byte buffer into ordered key events.

  Returns `{events, rest}` where `rest` is the unconsumed tail that forms
  an incomplete escape or UTF-8 sequence and must be prepended to the next
  decode call.
  """
  @spec decode(binary()) :: {[event()], binary()}
  def decode(buffer) when is_binary(buffer), do: decode(buffer, [])

  defp decode(<<>>, acc), do: {Enum.reverse(acc), <<>>}

  # Carriage return / line feed -> submit.
  defp decode(<<c, rest::binary>>, acc) when c in [10, 13],
    do: decode(rest, [KeyEvent.key(:enter) | acc])

  defp decode(<<9, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:tab) | acc])

  defp decode(<<1, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:ctrl_a) | acc])
  defp decode(<<2, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:ctrl_b) | acc])
  defp decode(<<3, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:ctrl_c) | acc])
  defp decode(<<4, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:ctrl_d) | acc])
  defp decode(<<5, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:ctrl_e) | acc])
  defp decode(<<6, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:ctrl_f) | acc])
  defp decode(<<7, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:ctrl_g) | acc])
  defp decode(<<11, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:ctrl_k) | acc])
  defp decode(<<14, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:ctrl_n) | acc])
  defp decode(<<16, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:ctrl_p) | acc])
  defp decode(<<18, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:ctrl_r) | acc])
  defp decode(<<21, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:ctrl_u) | acc])
  defp decode(<<23, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:ctrl_w) | acc])
  defp decode(<<25, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:ctrl_y) | acc])

  # DEL (127) and BS (8) both map to backspace across terminals.
  defp decode(<<c, rest::binary>>, acc) when c in [8, 127],
    do: decode(rest, [KeyEvent.key(:backspace) | acc])

  # CSI escape sequences: ESC [ ...
  defp decode(<<27, ?[, rest::binary>> = seq, acc) do
    case KeySequence.csi(rest) do
      {:ok, key, tail} -> decode(tail, [key | acc])
      :incomplete -> {Enum.reverse(acc), seq}
      :ignore_one -> decode(rest, acc)
    end
  end

  # SS3 escape sequences: ESC O <A-D> (application cursor mode).
  defp decode(<<27, ?O, c, rest::binary>>, acc) do
    case KeySequence.ss3(c) do
      {:ok, key} -> decode(rest, [key | acc])
      :error -> decode(rest, acc)
    end
  end

  # A lone ESC with nothing after it yet — could still grow into CSI/SS3.
  defp decode(<<27>>, acc), do: {Enum.reverse(acc), <<27>>}
  defp decode(<<27, ?O>>, acc), do: {Enum.reverse(acc), <<27, ?O>>}

  # Alt/Meta word editing shortcuts. Many terminals encode Option/Meta as
  # ESC + printable byte when enhanced keyboard mode is not enabled.
  defp decode(<<27, ?b, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:alt_b) | acc])
  defp decode(<<27, ?B, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:alt_b) | acc])
  defp decode(<<27, ?d, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:alt_d) | acc])
  defp decode(<<27, ?D, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:alt_d) | acc])
  defp decode(<<27, ?f, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:alt_f) | acc])
  defp decode(<<27, ?F, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:alt_f) | acc])
  defp decode(<<27, ?y, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:alt_y) | acc])
  defp decode(<<27, ?Y, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:alt_y) | acc])

  # ESC followed by a non-sequence byte: treat ESC as a standalone key and
  # continue decoding from the following byte.
  defp decode(<<27, rest::binary>>, acc), do: decode(rest, [KeyEvent.key(:escape) | acc])

  # Other C0 control bytes are not surfaced as editable input.
  defp decode(<<c, rest::binary>>, acc) when c < 32,
    do: decode(rest, acc)

  # Printable ASCII.
  defp decode(<<c, rest::binary>>, acc) when c >= 32 and c < 127,
    do: decode(rest, [KeyEvent.char(<<c>>) | acc])

  # UTF-8 multi-byte: emit one grapheme when complete, otherwise buffer the
  # incomplete lead bytes for the next read.
  defp decode(<<c, _::binary>> = buffer, acc) when c >= 0xC0 do
    case KeyUtf8.take(buffer) do
      {:ok, grapheme, rest} -> decode(rest, [KeyEvent.char(grapheme) | acc])
      :incomplete -> {Enum.reverse(acc), buffer}
      :invalid -> decode(binary_part(buffer, 1, byte_size(buffer) - 1), acc)
    end
  end

  # Stray UTF-8 continuation byte with no lead — drop it.
  defp decode(<<_c, rest::binary>>, acc), do: decode(rest, acc)
end
