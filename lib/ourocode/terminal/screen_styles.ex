defmodule Ourocode.Terminal.ScreenStyles do
  @moduledoc """
  ANSI SGR palette for terminal screen cells.
  """

  @reset "\e[0m"

  # 24-bit truecolor design system. Every style owns foreground and background:
  # light mode stays on white-toned surfaces, and dark mode stays on dark-toned
  # surfaces. Accents are restrained signals, not alternate surfaces.
  # Every entry leads with `0;` so each styled run is fully self-contained:
  # weight and colour reset before they are re-set, so a bold run never bleeds
  # into the dim run beside it on the same row.
  @dark_styles %{
    brand: "\e[0;1;48;2;10;10;11;38;2;102;217;194m",
    accent: "\e[0;48;2;10;10;11;38;2;232;164;92m",
    strong: "\e[0;1;48;2;10;10;11;38;2;245;245;247m",
    label: "\e[0;1;48;2;10;10;11;38;2;142;142;150m",
    dim: "\e[0;48;2;10;10;11;38;2;141;141;149m",
    muted: "\e[0;48;2;10;10;11;38;2;101;101;110m",
    border: "\e[0;48;2;10;10;11;38;2;58;58;64m",
    title: "\e[0;1;48;2;10;10;11;38;2;102;217;194m",
    ok: "\e[0;48;2;10;10;11;38;2;102;217;194m",
    warn: "\e[0;48;2;10;10;11;38;2;232;164;92m",
    err: "\e[0;48;2;10;10;11;38;2;248;81;73m",
    placeholder: "\e[0;48;2;10;10;11;38;2;84;84;93m",
    text: "\e[0;48;2;10;10;11;38;2;226;226;229m",
    command: "\e[0;1;48;2;10;10;11;38;2;125;180;255m",
    p_fill: "\e[0;48;2;17;17;17;38;2;224;224;224m",
    p_title: "\e[0;1;48;2;17;17;17;38;2;224;224;224m",
    p_accent: "\e[0;1;48;2;17;17;17;38;2;102;217;194m",
    p_dim: "\e[0;48;2;17;17;17;38;2;168;168;168m",
    p_muted: "\e[0;48;2;17;17;17;38;2;104;104;104m",
    p_err: "\e[0;48;2;17;17;17;38;2;223;138;138m"
  }

  @light_styles %{
    brand: "\e[0;1;48;2;250;250;249;38;2;20;102;90m",
    accent: "\e[0;48;2;250;250;249;38;2;153;96;35m",
    strong: "\e[0;1;48;2;250;250;249;38;2;23;23;25m",
    label: "\e[0;1;48;2;250;250;249;38;2;96;96;104m",
    dim: "\e[0;48;2;250;250;249;38;2;92;92;99m",
    muted: "\e[0;48;2;250;250;249;38;2;122;122;130m",
    border: "\e[0;48;2;250;250;249;38;2;218;218;214m",
    title: "\e[0;1;48;2;250;250;249;38;2;20;102;90m",
    ok: "\e[0;48;2;250;250;249;38;2;20;102;90m",
    warn: "\e[0;48;2;250;250;249;38;2;153;96;35m",
    err: "\e[0;48;2;250;250;249;38;2;181;42;42m",
    placeholder: "\e[0;48;2;250;250;249;38;2;153;153;158m",
    text: "\e[0;48;2;250;250;249;38;2;34;34;38m",
    command: "\e[0;1;48;2;250;250;249;38;2;38;92;198m",
    p_fill: "\e[0;48;2;242;242;240;38;2;42;42;46m",
    p_title: "\e[0;1;48;2;242;242;240;38;2;34;34;38m",
    p_accent: "\e[0;1;48;2;242;242;240;38;2;20;102;90m",
    p_dim: "\e[0;48;2;242;242;240;38;2;82;82;88m",
    p_muted: "\e[0;48;2;242;242;240;38;2;132;132;138m",
    p_err: "\e[0;48;2;242;242;240;38;2;181;42;42m"
  }

  @type style ::
          :brand
          | :accent
          | :strong
          | :label
          | :dim
          | :muted
          | :border
          | :title
          | :ok
          | :warn
          | :err
          | :placeholder
          | :text
          | :command
          | :p_fill
          | :p_title
          | :p_accent
          | :p_dim
          | :p_muted
          | :p_err

  @spec reset() :: String.t()
  def reset, do: @reset

  @spec sgr(style()) :: String.t()
  def sgr(style), do: sgr(style, theme())

  @spec sgr(style(), :dark | :light) :: String.t()
  def sgr(style, theme) when theme in [:dark, :light], do: Map.fetch!(styles(theme), style)

  @spec styles(:dark | :light) :: map()
  def styles(:dark), do: @dark_styles
  def styles(:light), do: @light_styles

  @spec theme() :: :dark | :light
  def theme, do: theme(System.get_env())

  @spec theme(map()) :: :dark | :light
  def theme(env) when is_map(env) do
    case env |> Map.get("OUROCODE_THEME", "") |> String.downcase() do
      value when value in ["light", "white"] -> :light
      "dark" -> :dark
      _unset -> detect_theme(env)
    end
  end

  # No explicit override: read the terminal's own background from COLORFGBG
  # so a dark terminal gets the dark surface instead of a white box, and a
  # light terminal keeps the light surface. Default dark when unknown — most
  # developer terminals are dark, and the dark surface (near-black) reads
  # acceptably on any background while a white surface does not.
  defp detect_theme(env) do
    case env |> Map.get("COLORFGBG", "") |> terminal_background() do
      :light -> :light
      :dark -> :dark
      :unknown -> :dark
    end
  end

  # COLORFGBG is "fg;bg" or "fg;extra;bg"; the last field is the background
  # ANSI colour index. 0-6 and 8 are dark; 7 and 9-15 are light.
  defp terminal_background(colorfgbg) do
    case colorfgbg |> String.split(";") |> List.last() do
      nil ->
        :unknown

      field ->
        case Integer.parse(String.trim(field)) do
          {index, ""} when index in [0, 1, 2, 3, 4, 5, 6, 8] -> :dark
          {index, ""} when index in [7, 9, 10, 11, 12, 13, 14, 15] -> :light
          _other -> :unknown
        end
    end
  end

  @spec styled?(style() | nil) :: boolean()
  def styled?(style), do: not is_nil(style)
end
