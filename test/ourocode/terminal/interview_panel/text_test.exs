defmodule Ourocode.Terminal.InterviewPanel.TextTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.InterviewPanel.Text

  test "md_text strips lightweight markdown and unstable glyphs" do
    assert Text.md_text("# **Hello** [there](https://example.com) `friend` 👋") ==
             "Hello there friend"
  end

  test "flatten_line normalizes markdown and whitespace" do
    assert Text.flatten_line("**Hello**\n\n`world`") == "Hello world"
  end

  test "flatten_line keeps Korean PM option text while stripping unstable glyphs" do
    option =
      <<234, 176>> <>
        " - " <>
        hangul([0xC778]) <>
        " " <>
        hangul([0xD074, 0xB9AC, 0xC5D0, 0xC774, 0xD130]) <>
        " | " <>
        hangul([0xC778, 0xC2A4, 0xD0C0, 0xADF8, 0xB7A8]) <>
        ", " <>
        hangul([0xBE14, 0xB85C, 0xADF8]) <>
        ", " <>
        hangul([0xB274, 0xC2A4, 0xB808, 0xD130]) <>
        hangul([0xC6A9]) <>
        " " <>
        hangul([0xCF58, 0xD150, 0xCE20]) <>
        hangul([0xB97C]) <>
        " " <>
        hangul([0xD63C, 0xC790]) <>
        " " <>
        hangul([0xBE60, 0xB974, 0xAC8C]) <>
        " " <>
        hangul([0xB9CC, 0xB4DC, 0xB294]) <>
        " " <>
        hangul([0xC0AC, 0xB78C]) <>
        " " <>
        <<0x1F44B::utf8>>

    assert Text.flatten_line(option) ==
             "- " <>
               hangul([0xC778]) <>
               " " <>
               hangul([0xD074, 0xB9AC, 0xC5D0, 0xC774, 0xD130]) <>
               " | " <>
               hangul([0xC778, 0xC2A4, 0xD0C0, 0xADF8, 0xB7A8]) <>
               ", " <>
               hangul([0xBE14, 0xB85C, 0xADF8]) <>
               ", " <>
               hangul([0xB274, 0xC2A4, 0xB808, 0xD130]) <>
               hangul([0xC6A9]) <>
               " " <>
               hangul([0xCF58, 0xD150, 0xCE20]) <>
               hangul([0xB97C]) <>
               " " <>
               hangul([0xD63C, 0xC790]) <>
               " " <>
               hangul([0xBE60, 0xB974, 0xAC8C]) <>
               " " <>
               hangul([0xB9CC, 0xB4DC, 0xB294]) <>
               " " <>
               hangul([0xC0AC, 0xB78C])
  end

  test "plain_line only collapses whitespace" do
    assert Text.plain_line(" **Hello**\n world ") == "**Hello** world"
  end

  test "normalizes model-spaced Hangul syllable runs" do
    spaced = hangul([0xC778, 0xD130, 0xBDF0]) <> " UX " <> hangul([0xD750, 0xB984])
    compact = hangul([0xC778, 0xD130, 0xBDF0]) <> " UX " <> hangul([0xD750, 0xB984])

    spaced =
      spaced
      |> String.graphemes()
      |> Enum.join(" ")
      |> String.replace(" U X ", " UX ")

    assert Text.md_text(spaced) == compact
    assert Text.flatten_line(spaced) == compact
    assert Text.plain_line(spaced) == compact
  end

  test "normalizes short model-spaced Hangul option labels" do
    spaced = hangul([0xC810]) <> " " <> hangul([0xAC80])
    compact = hangul([0xC810, 0xAC80])

    assert Text.md_text(spaced) == compact
  end

  test "keeps deliberate Hangul word boundaries when the source has wider gaps" do
    first = hangul([0xC778, 0xD130, 0xBDF0])
    second = hangul([0xD50C, 0xB85C, 0xC6B0])

    spaced =
      Enum.join(String.graphemes(first), " ") <> "  " <> Enum.join(String.graphemes(second), " ")

    assert Text.md_text(spaced) == first <> " " <> second
  end

  test "keeps existing Hangul word boundaries in natural prose" do
    first = hangul([0xC6B4, 0xC601])
    second = hangul([0xC911])
    third = hangul([0xC2E4, 0xD328])
    fourth = hangul([0xCF00, 0xC774, 0xC2A4])
    fifth = hangul([0xB300, 0xC751])
    sixth = hangul([0xC911])

    prose = Enum.join([first, second, third, fourth, fifth, sixth], " ")

    assert Text.md_text(prose) == prose
  end

  test "keeps mixed-length Hangul words instead of over-compacting natural prose" do
    first = hangul([0xC6B4, 0xC601])
    second = hangul([0xC911])
    third = hangul([0xC2E4, 0xD328])
    fourth = hangul([0xCF00, 0xC774, 0xC2A4])
    fifth = hangul([0xB300, 0xC751])
    sixth = hangul([0xC911])
    seventh = hangul([0xC5B4, 0xB514, 0xAC00])

    prose = Enum.join([first, second, third, fourth, fifth, sixth, seventh], " ")

    assert Text.md_text(prose) == prose
  end

  test "restores known Hangul boundaries in model-spaced operational prose" do
    first = hangul([0xC6B4, 0xC601])
    second = hangul([0xC911])
    third = hangul([0xC2E4, 0xD328])
    fourth = hangul([0xCF00, 0xC774, 0xC2A4])
    fifth = hangul([0xB300, 0xC751])
    sixth = hangul([0xC911])

    spaced =
      [first <> second, third <> fourth, fifth <> sixth]
      |> Enum.join("  ")
      |> String.graphemes()
      |> Enum.join(" ")
      |> String.replace("    ", "  ")

    assert Text.md_text(spaced) == Enum.join([first, second, third, fourth, fifth, sixth], " ")
  end

  test "restores known Hangul boundaries after compacting a model-spaced option" do
    first = hangul([0xC6B4, 0xC601])
    second = hangul([0xC911])
    third = hangul([0xC2E4, 0xD328])
    fourth = hangul([0xCF00, 0xC774, 0xC2A4])
    fifth = hangul([0xB300, 0xC751])
    sixth = hangul([0xC911])
    seventh = hangul([0xC5B4, 0xB514, 0xAC00])

    spaced =
      [first, second, third, fourth, fifth, sixth, seventh]
      |> Enum.join()
      |> String.graphemes()
      |> Enum.join(" ")

    assert Text.md_text(spaced) ==
             Enum.join([first, second, third, fourth, fifth, sixth, seventh], " ")
  end

  test "restores quality and execution phrase boundaries after compacting a model-spaced option" do
    first = hangul([0xC9C8, 0xBB38])
    second = hangul([0xD488, 0xC9C8])
    third = hangul([0xBB38, 0xC81C])
    fourth = hangul([0xC5B4, 0xB514, 0xAC00])

    spaced =
      [first, second, third, fourth]
      |> Enum.join()
      |> String.graphemes()
      |> Enum.join(" ")

    assert Text.md_text(spaced) == Enum.join([first, second, third, fourth], " ")
  end

  test "restores common interview phrase boundaries after compacting a model-spaced option" do
    first = hangul([0xC778, 0xD130, 0xBDF0])
    second = hangul([0xD50C, 0xB85C, 0xC6B0, 0xB97C])
    third = hangul([0xC804, 0xBC18, 0xC801, 0xC73C, 0xB85C])
    fourth = hangul([0xC810, 0xAC80])

    spaced =
      [first, second, third, fourth]
      |> Enum.join()
      |> String.graphemes()
      |> Enum.join(" ")

    assert Text.md_text(spaced) == Enum.join([first, second, third, fourth], " ")
  end

  defp hangul(codepoints) do
    codepoints
    |> Enum.map(&<<&1::utf8>>)
    |> Enum.join()
  end
end
