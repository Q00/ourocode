defmodule Ourocode.Terminal.KeyBracketedPaste do
  @moduledoc """
  Parser for bracketed paste payloads inside CSI terminal sequences.

  `KeySequence` detects the opening `ESC [ 200~` marker and passes the body
  here. This module waits for the closing `ESC [ 201~` marker and returns the
  pasted text plus any trailing bytes.
  """

  alias Ourocode.Terminal.KeyEvent
  @max_payload_bytes 4_194_304

  @closing_marker "\e[201~"

  @type result :: {:ok, map(), binary()} | :incomplete | :overflow

  @spec parse(binary()) :: result()
  def parse(tail) when is_binary(tail) do
    cond do
      byte_size(tail) > @max_payload_bytes ->
        :overflow

      match?({_, _}, :binary.match(tail, @closing_marker)) ->
        {idx, _len} = :binary.match(tail, @closing_marker)
        text = binary_part(tail, 0, idx)

        rest =
          binary_part(
            tail,
            idx + byte_size(@closing_marker),
            byte_size(tail) - idx - byte_size(@closing_marker)
          )

        {:ok, KeyEvent.paste(text), rest}

      true ->
        :incomplete
    end
  end
end
