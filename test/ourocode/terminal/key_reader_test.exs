defmodule Ourocode.Terminal.KeyReaderTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.KeyReader

  defp keys(buffer) do
    {events, rest} = KeyReader.decode(buffer)
    {Enum.map(events, &{&1.key, &1.char}), rest}
  end

  test "decodes printable ASCII as char events" do
    assert {[{:char, "a"}, {:char, "b"}, {:char, "c"}], ""} = keys("abc")
  end

  test "decodes enter, tab, backspace, and ctrl-c control bytes" do
    assert {[{:enter, nil}], ""} = keys("\r")
    assert {[{:enter, nil}], ""} = keys("\n")
    assert {[{:tab, nil}], ""} = keys(<<9>>)
    assert {[{:backspace, nil}], ""} = keys(<<127>>)
    assert {[{:backspace, nil}], ""} = keys(<<8>>)
    assert {[{:ctrl_c, nil}], ""} = keys(<<3>>)
    assert {[{:ctrl_d, nil}], ""} = keys(<<4>>)
  end

  test "decodes Ctrl-R as the reverse-search key" do
    assert {[{:ctrl_r, nil}], ""} = keys(<<18>>)
  end

  test "decodes readline-style editing controls" do
    assert {
             [
               {:ctrl_a, nil},
               {:ctrl_b, nil},
               {:ctrl_e, nil},
               {:ctrl_f, nil},
               {:ctrl_g, nil},
               {:ctrl_k, nil},
               {:ctrl_n, nil},
               {:ctrl_p, nil},
               {:ctrl_u, nil},
               {:ctrl_w, nil},
               {:ctrl_y, nil}
             ],
             ""
           } = keys(<<1, 2, 5, 6, 7, 11, 14, 16, 21, 23, 25>>)
  end

  test "decodes alt/meta word editing shortcuts" do
    assert {[{:alt_b, nil}, {:alt_d, nil}, {:alt_f, nil}, {:alt_y, nil}], ""} =
             keys("\eb\ed\ef\ey")
  end

  test "decodes enhanced keyboard backspace modifiers" do
    assert {[{:cmd_backspace, nil}], ""} = keys("\e[127;9u")
    assert {[{:ctrl_backspace, nil}], ""} = keys("\e[127;5u")
    assert {[{:cmd_backspace, nil}], ""} = keys("\e[27;9;127~")
  end

  test "decodes command zoom keys without leaking printable input" do
    assert {[{:cmd_plus, nil}, {:cmd_plus, nil}, {:cmd_minus, nil}], ""} =
             keys("\e[43;9u\e[61;9u\e[45;9u")
  end

  test "decodes CSI arrow, navigation, and tilde sequences" do
    assert {[{:up, nil}, {:down, nil}, {:right, nil}, {:left, nil}], ""} =
             keys("\e[A\e[B\e[C\e[D")

    assert {[{:home, nil}, {:end, nil}], ""} = keys("\e[H\e[F")
    assert {[{:delete, nil}], ""} = keys("\e[3~")
    assert {[{:page_up, nil}, {:page_down, nil}], ""} = keys("\e[5~\e[6~")
  end

  test "decodes modified CSI arrows emitted by common terminals" do
    assert {[{:up, nil}, {:down, nil}, {:alt_f, nil}, {:alt_b, nil}], ""} =
             keys("\e[1;5A\e[1;5B\e[1;3C\e[1;5D")
  end

  test "decodes modified tilde navigation sequences by their base key" do
    assert {[{:home, nil}, {:delete, nil}, {:page_up, nil}, {:page_down, nil}], ""} =
             keys("\e[1;5~\e[3;2~\e[5;3~\e[6;4~")
  end

  test "decodes SS3 application-cursor arrow sequences" do
    assert {[{:up, nil}, {:left, nil}], ""} = keys("\eOA\eOD")
  end

  test "treats a standalone ESC as an escape key" do
    assert {[{:escape, nil}, {:char, "x"}], ""} = keys(<<27, ?x>>)
  end

  test "buffers an incomplete CSI escape as trailing bytes" do
    assert {[{:char, "a"}], "\e["} = keys("a\e[")
    assert {[], "\e[5"} = keys("\e[5")
    assert {[], <<27>>} = keys(<<27>>)
  end

  test "resumes a split escape sequence across two decode calls" do
    {events, rest} = KeyReader.decode("\e[")
    assert events == []
    {events2, rest2} = KeyReader.decode(rest <> "A")
    assert Enum.map(events2, & &1.key) == [:up]
    assert rest2 == ""
  end

  test "decodes bracketed paste as a single paste event" do
    {[event], ""} = KeyReader.decode("\e[200~hello\n/tmp/image.png\e[201~")
    assert event.key == :paste
    assert event.char == "hello\n/tmp/image.png"
  end

  test "buffers incomplete bracketed paste until the closing marker arrives" do
    {events, rest} = KeyReader.decode("\e[200~partial")
    assert events == []
    assert rest == "\e[200~partial"

    {[event], ""} = KeyReader.decode(rest <> "\e[201~")
    assert event.key == :paste
    assert event.char == "partial"
  end

  test "drops oversized incomplete bracketed paste and resumes ordinary input" do
    {events, rest} = KeyReader.decode("\e[200~" <> String.duplicate("x", 4_194_305))
    assert events == []
    assert rest == ""

    {[event], ""} = KeyReader.decode("z")
    assert event.key == :char
    assert event.char == "z"
  end

  test "decodes a multi-byte UTF-8 grapheme and buffers an incomplete tail" do
    assert {[{:char, "界"}], ""} = keys("界")

    <<lead, tail::binary>> = "中"
    assert {[], buffered} = keys(<<lead>>)
    assert buffered == <<lead>>

    {events, rest} = KeyReader.decode(<<lead>> <> tail)
    assert Enum.map(events, & &1.char) == ["中"]
    assert rest == ""
  end

  test "mixes printable, control, and escape input in order" do
    {events, ""} = KeyReader.decode("hi\e[B\r")

    assert Enum.map(events, &{&1.key, &1.char}) == [
             {:char, "h"},
             {:char, "i"},
             {:down, nil},
             {:enter, nil}
           ]
  end

  test "decodes SGR mouse wheel, hover, and button reports" do
    {[wheel_up], ""} = KeyReader.decode("\e[<64;10;20M")
    assert %{type: :mouse, key: :wheel_up, x: 10, y: 20} = wheel_up

    {[wheel_down], ""} = KeyReader.decode("\e[<65;3;4M")
    assert %{type: :mouse, key: :wheel_down} = wheel_down

    {[button], ""} = KeyReader.decode("\e[<0;5;6M")
    assert %{type: :mouse, key: :mouse_down, x: 5, y: 6} = button

    {[hover], ""} = KeyReader.decode("\e[<35;7;8M")
    assert %{type: :mouse, key: :mouse_move, x: 7, y: 8} = hover

    # Wheel events still interleave correctly with text.
    {events, ""} = KeyReader.decode("a\e[<64;1;1Mb")
    assert Enum.map(events, & &1.key) == [:char, :wheel_up, :char]
  end

  test "buffers an incomplete SGR mouse sequence as trailing bytes" do
    {events, rest} = KeyReader.decode("\e[<64;10")
    assert events == []
    assert rest == "\e[<64;10"

    {[wheel_up], ""} = KeyReader.decode(rest <> ";20M")
    assert wheel_up.key == :wheel_up
  end
end
