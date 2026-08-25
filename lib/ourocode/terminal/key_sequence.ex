defmodule Ourocode.Terminal.KeySequence do
  @moduledoc """
  Decodes ANSI terminal key escape sequence bodies.

  `KeyReader` owns streaming byte-buffer handling. This module owns the
  terminal-sequence grammar for CSI, SS3, bracketed paste, modified keys, and
  SGR mouse reports.
  """

  alias Ourocode.Terminal.{KeyBracketedPaste, KeyEvent, KeyModifiers, KeySgrMouse}

  @spec csi(binary()) :: {:ok, map(), binary()} | :incomplete | :overflow | :ignore_one
  def csi(rest) when is_binary(rest) do
    case rest do
      <<?<, tail::binary>> -> KeySgrMouse.parse(tail)
      <<?2, ?0, ?0, ?~, tail::binary>> -> KeyBracketedPaste.parse(tail)
      _other -> csi_sequence(rest, "")
    end
  end

  @spec ss3(byte()) :: {:ok, map()} | :error
  def ss3(c) do
    case arrow(c) do
      {:ok, name} -> {:ok, KeyEvent.key(name)}
      :error -> :error
    end
  end

  defp csi_sequence(<<>>, _params), do: :incomplete

  defp csi_sequence(<<final, tail::binary>>, params)
       when final in [?A, ?B, ?C, ?D, ?H, ?F, ?~, ?u] do
    csi_final(final, params, tail)
  end

  defp csi_sequence(<<d, tail::binary>>, params) when d in ?0..?9 or d == ?;,
    do: csi_sequence(tail, params <> <<d>>)

  defp csi_sequence(_other, _params), do: :ignore_one

  defp csi_final(final, params, tail) when final in [?A, ?B, ?C, ?D] do
    case KeyModifiers.arrow(final, params) do
      nil ->
        case arrow(final) do
          {:ok, name} -> {:ok, KeyEvent.key(name), tail}
          :error -> :ignore_one
        end

      name ->
        {:ok, KeyEvent.key(name), tail}
    end
  end

  defp csi_final(?H, _params, tail), do: {:ok, KeyEvent.key(:home), tail}
  defp csi_final(?F, _params, tail), do: {:ok, KeyEvent.key(:end), tail}

  defp csi_final(?u, params, tail) do
    case KeyModifiers.key(params) do
      nil -> :ignore_one
      name -> {:ok, KeyEvent.key(name), tail}
    end
  end

  defp csi_final(?~, params, tail) do
    case KeyModifiers.key(params) do
      nil ->
        case params |> String.split(";", parts: 2) |> List.first() do
          n when n in ["1", "7"] -> {:ok, KeyEvent.key(:home), tail}
          n when n in ["4", "8"] -> {:ok, KeyEvent.key(:end), tail}
          "3" -> {:ok, KeyEvent.key(:delete), tail}
          "5" -> {:ok, KeyEvent.key(:page_up), tail}
          "6" -> {:ok, KeyEvent.key(:page_down), tail}
          _other -> :ignore_one
        end

      name ->
        {:ok, KeyEvent.key(name), tail}
    end
  end

  defp arrow(?A), do: {:ok, :up}
  defp arrow(?B), do: {:ok, :down}
  defp arrow(?C), do: {:ok, :right}
  defp arrow(?D), do: {:ok, :left}
  defp arrow(_other), do: :error
end
