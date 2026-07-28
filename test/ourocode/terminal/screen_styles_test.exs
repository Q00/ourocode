defmodule Ourocode.Terminal.ScreenStylesTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.ScreenStyles

  test "returns reset and SGR codes for screen styles" do
    assert ScreenStyles.reset() == "\e[0m"
    assert ScreenStyles.sgr(:text, :dark) == "\e[0;48;2;10;10;11;38;2;226;226;229m"
    assert ScreenStyles.sgr(:ok, :dark) == "\e[0;48;2;10;10;11;38;2;102;217;194m"
  end

  test "command style is theme-owned and distinct from the ooo/brand highlight" do
    assert ScreenStyles.styled?(:command)
    assert ScreenStyles.sgr(:command, :dark) != ScreenStyles.sgr(:command, :light)
    refute ScreenStyles.sgr(:command, :dark) == ScreenStyles.sgr(:brand, :dark)
    refute ScreenStyles.sgr(:command, :light) == ScreenStyles.sgr(:brand, :light)
  end

  test "styled? treats nil as unstyled and text as theme-owned" do
    refute ScreenStyles.styled?(nil)
    assert ScreenStyles.styled?(:text)
    assert ScreenStyles.styled?(:warn)
  end

  test "explicit OUROCODE_THEME wins over terminal detection" do
    assert ScreenStyles.theme(%{"OUROCODE_THEME" => "light"}) == :light
    assert ScreenStyles.theme(%{"OUROCODE_THEME" => "white"}) == :light
    assert ScreenStyles.theme(%{"OUROCODE_THEME" => "dark"}) == :dark
    # Override beats a conflicting COLORFGBG.
    assert ScreenStyles.theme(%{"OUROCODE_THEME" => "light", "COLORFGBG" => "15;0"}) == :light
  end

  test "theme follows the terminal background from COLORFGBG" do
    # Last field is the background colour index: 0-6,8 dark; 7,9-15 light.
    assert ScreenStyles.theme(%{"COLORFGBG" => "15;0"}) == :dark
    assert ScreenStyles.theme(%{"COLORFGBG" => "0;15"}) == :light
    assert ScreenStyles.theme(%{"COLORFGBG" => "1;7"}) == :light
    assert ScreenStyles.theme(%{"COLORFGBG" => "15;default;0"}) == :dark
  end

  test "theme defaults to dark when the terminal background is unknown" do
    # A dark surface reads on any terminal; a white box does not. Default dark.
    assert ScreenStyles.theme(%{}) == :dark
    assert ScreenStyles.theme(%{"COLORFGBG" => ""}) == :dark
    assert ScreenStyles.theme(%{"COLORFGBG" => "garbage"}) == :dark
  end

  test "light theme surfaces stay light-toned and dark theme surfaces stay dark-toned" do
    assert_bg(ScreenStyles.sgr(:text, :light), {250, 250, 249})
    assert_bg(ScreenStyles.sgr(:p_fill, :light), {242, 242, 240})
    assert_bg(ScreenStyles.sgr(:text, :dark), {10, 10, 11})
    assert_bg(ScreenStyles.sgr(:p_fill, :dark), {17, 17, 17})

    light_bgs = background_values(ScreenStyles.styles(:light))
    dark_bgs = background_values(ScreenStyles.styles(:dark))

    assert Enum.all?(light_bgs, fn {r, g, b} -> r >= 240 and g >= 240 and b >= 240 end)
    assert Enum.all?(dark_bgs, fn {r, g, b} -> r <= 24 and g <= 24 and b <= 24 end)
  end

  defp assert_bg(sgr, expected), do: assert(bg(sgr) == expected)

  defp background_values(styles) do
    styles
    |> Map.values()
    |> Enum.map(&bg/1)
  end

  defp bg(sgr) do
    [_, r, g, b] = Regex.run(~r/48;2;(\d+);(\d+);(\d+)/, sgr)
    {String.to_integer(r), String.to_integer(g), String.to_integer(b)}
  end
end
