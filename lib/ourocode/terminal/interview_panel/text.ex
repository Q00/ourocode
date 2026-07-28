defmodule Ourocode.Terminal.InterviewPanel.Text do
  @moduledoc """
  Text normalization helpers for interview panel rendering.
  """

  @hangul_syllable_re ~r/[\x{AC00}-\x{D7A3}]/u
  @hangul_syllable_single_gap_re ~r/(?<=[\x{AC00}-\x{D7A3}])[\t ](?=[\x{AC00}-\x{D7A3}])/u
  @hangul_adjacent_syllable_re ~r/[\x{AC00}-\x{D7A3}]{2}/u
  @spaced_hangul_run_re ~r/(?<![\x{AC00}-\x{D7A3}])(?:[\x{AC00}-\x{D7A3}][\t ])+[\x{AC00}-\x{D7A3}](?![\x{AC00}-\x{D7A3}])/u
  @hangul_word_hint_codepoints [
    [0xC804, 0xBC18, 0xC801, 0xC73C, 0xB85C],
    [0xD50C, 0xB85C, 0xC6B0, 0xB97C],
    [0xC9C8, 0xBB38],
    [0xD488, 0xC9C8],
    [0xBB38, 0xC81C],
    [0xC2E4, 0xD589],
    [0xB2E8, 0xACC4],
    [0xC6B4, 0xC601],
    [0xC2E4, 0xD328],
    [0xCF00, 0xC774, 0xC2A4],
    [0xB300, 0xC751],
    [0xC778, 0xD130, 0xBDF0],
    [0xD50C, 0xB85C, 0xC6B0],
    [0xB300, 0xC751],
    [0xC911],
    [0xC5B4, 0xB514, 0xAC00],
    [0xC810, 0xAC80],
    [0xD750, 0xB984]
  ]

  @spec md_text(term()) :: String.t()
  def md_text(text) do
    text
    |> to_string()
    |> scrub_invalid_utf8()
    |> String.replace(~r/(\*\*|__)(.*?)\1/s, "\\2")
    |> String.replace(~r/(\*|_)(.*?)\1/s, "\\2")
    |> String.replace(~r/`([^`]+)`/, "\\1")
    |> String.replace(~r/^\s{0,3}\#{1,6}\s+/m, "")
    |> String.replace(~r/\[([^\]]+)\]\([^)]+\)/, "\\1")
    |> strip_unstable_glyphs()
    |> repair_hangul_syllable_spacing()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @spec flatten_line(term()) :: String.t()
  def flatten_line(text) do
    text
    |> md_text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @spec plain_line(term()) :: String.t()
  def plain_line(text) do
    text
    |> to_string()
    |> scrub_invalid_utf8()
    |> repair_hangul_syllable_spacing()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp strip_unstable_glyphs(text) do
    text
    |> String.replace(~r/[\x{FFFD}\x{FE0E}\x{FE0F}\x{200D}]/u, "")
    |> strip_supplemental_symbols()
  end

  defp scrub_invalid_utf8(text) do
    String.replace_invalid(text, "")
  end

  defp strip_supplemental_symbols(text) do
    text
    |> String.graphemes()
    |> Enum.reject(&supplemental_symbol?/1)
    |> Enum.join()
  end

  defp supplemental_symbol?(grapheme) do
    grapheme
    |> String.to_charlist()
    |> Enum.any?(&(&1 in 0x1F000..0x1FAFF))
  end

  defp repair_hangul_syllable_spacing(text) do
    text
    |> String.split(~r/([ \t]{2,})/, include_captures: true, trim: false)
    |> Enum.map(fn segment ->
      cond do
        Regex.match?(~r/^[ \t]{2,}$/u, segment) ->
          segment

        true ->
          repair_hangul_segment(segment)
      end
    end)
    |> Enum.join()
  end

  defp repair_hangul_segment(segment) do
    Regex.replace(@spaced_hangul_run_re, segment, fn run ->
      if spaced_hangul_run?(run) do
        run
        |> String.replace(@hangul_syllable_single_gap_re, "")
        |> split_repaired_hangul_run()
      else
        run
      end
    end)
  end

  defp split_repaired_hangul_run(text) do
    case segment_known_hangul_terms(text) do
      {:ok, segments} -> Enum.join(segments, " ")
      :error -> text
    end
  end

  defp segment_known_hangul_terms(text) do
    case segment_known_hangul_terms(text, []) do
      {:ok, [_one]} -> :error
      {:ok, segments} -> {:ok, segments}
      :error -> :error
    end
  end

  defp segment_known_hangul_terms("", segments), do: {:ok, Enum.reverse(segments)}

  defp segment_known_hangul_terms(text, segments) do
    hangul_word_hints()
    |> Enum.find(&String.starts_with?(text, &1))
    |> case do
      nil ->
        :error

      hint ->
        hint_length = String.length(hint)
        rest = String.slice(text, hint_length, String.length(text) - hint_length)
        segment_known_hangul_terms(rest, [hint | segments])
    end
  end

  defp hangul_word_hints do
    @hangul_word_hint_codepoints
    |> Enum.map(fn codepoints ->
      codepoints
      |> Enum.map(&<<&1::utf8>>)
      |> Enum.join()
    end)
    |> Enum.sort_by(&String.length/1, :desc)
  end

  defp spaced_hangul_run?(run) do
    hangul_count = @hangul_syllable_re |> Regex.scan(run) |> length()
    gap_count = @hangul_syllable_single_gap_re |> Regex.scan(run) |> length()

    not Regex.match?(@hangul_adjacent_syllable_re, run) and
      ((gap_count >= 2 and gap_count + 1 == hangul_count) or
         (hangul_count == 2 and gap_count == 1))
  end
end
