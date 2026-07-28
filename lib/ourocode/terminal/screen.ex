defmodule Ourocode.Terminal.Screen do
  @moduledoc """
  Pure ANSI screen-buffer compositor with row-level diffing.

  The Elixir runtime stays the source of truth for the render model; this
  module is a presentation-only cell grid. Callers paint boxes and text by
  coordinate, then either emit a full ANSI frame or a minimal diff against
  the previously emitted buffer so a persistent terminal app redraws in
  place instead of scrolling an append log. It owns no IO or process state.
  """

  alias Ourocode.Terminal.{ScreenStyles, ScreenText}

  @type style :: ScreenStyles.style()
  @type t :: %{
          required(:width) => pos_integer(),
          required(:height) => pos_integer(),
          required(:rows) => %{
            optional(non_neg_integer()) => %{optional(non_neg_integer()) => {String.t(), style()}}
          }
        }

  @doc """
  Builds an empty `width` x `height` screen buffer.
  """
  @spec new(pos_integer(), pos_integer()) :: t()
  def new(width, height) when width > 0 and height > 0 do
    %{width: width, height: height, rows: %{}}
  end

  @doc """
  Writes `text` starting at `{x, y}`, clipped to the screen width.
  """
  @spec put_text(t(), non_neg_integer(), non_neg_integer(), String.t(), style()) :: t()
  def put_text(%{width: width, height: height} = screen, x, y, text, style \\ :text)
      when is_integer(x) and is_integer(y) and is_binary(text) do
    if y < 0 or y >= height do
      screen
    else
      text
      |> String.graphemes()
      |> Enum.reduce({screen, x}, fn grapheme, {acc, col} ->
        w = ScreenText.char_width(grapheme)

        cond do
          col < 0 or col + w > width ->
            {acc, col + w}

          w == 2 ->
            acc =
              acc
              |> put_cell(col, y, {grapheme, style})
              |> put_cell(col + 1, y, {:cont, style})

            {acc, col + 2}

          true ->
            {put_cell(acc, col, y, {grapheme, style}), col + 1}
        end
      end)
      |> elem(0)
    end
  end

  @doc """
  Paints a `w` x `h` rectangle of spaces in `style` from `{x, y}`, clipped to
  the screen. Used to lay a shaded surface down before drawing content on top
  of it; content drawn afterwards (in a style carrying the same background)
  keeps the fill continuous. `to_lines/1` trims the spaces, so a fill never
  changes the plain-text projection.
  """
  @spec fill_rect(t(), non_neg_integer(), non_neg_integer(), integer(), integer(), style()) :: t()
  def fill_rect(%{width: width, height: height} = screen, x, y, w, h, style)
      when is_integer(x) and is_integer(y) do
    xs = max(x, 0)..min(x + w - 1, width - 1)//1
    ys = max(y, 0)..min(y + h - 1, height - 1)//1

    Enum.reduce(ys, screen, fn row, acc ->
      Enum.reduce(xs, acc, fn col, inner ->
        put_cell(inner, col, row, {" ", style})
      end)
    end)
  end

  @doc "Display columns a grapheme occupies (fullwidth = 2, else 1)."
  @spec char_width(String.t()) :: 1 | 2
  defdelegate char_width(grapheme), to: ScreenText

  @doc "Total display width of a string."
  @spec text_width(String.t()) :: non_neg_integer()
  defdelegate text_width(text), to: ScreenText

  @doc "Truncates `text` to at most `max` display columns."
  @spec truncate(String.t(), integer()) :: String.t()
  defdelegate truncate(text, max), to: ScreenText

  @doc """
  Draws a clean rounded box with an optional inline title in the top border.
  """
  @spec box(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          String.t() | nil,
          style()
        ) ::
          t()
  def box(screen, x, y, w, h, title \\ nil, style \\ :border)
      when w >= 2 and h >= 2 do
    top = box_top(w, title)
    bottom = "+" <> String.duplicate("-", w - 2) <> "+"

    screen
    |> put_text(x, y, top, style)
    |> draw_sides(x, y, w, h, style)
    |> put_text(x, y + h - 1, bottom, style)
  end

  @doc """
  Renders the full buffer as a cursor-home ANSI frame.
  """
  @spec to_ansi(t()) :: iodata()
  def to_ansi(%{height: height} = screen) do
    body =
      Enum.map(0..(height - 1), fn y ->
        ["\e[", Integer.to_string(y + 1), ";1H\e[2K", render_row(screen, y)]
      end)

    # Clear the whole viewport first so a shrunk frame leaves no orphan rows
    # below it and a resized terminal cannot show stale columns.
    ["\e[2J\e[H", body, ScreenStyles.reset()]
  end

  @doc """
  Emits ANSI updates only for rows that changed since `previous`.

  Returns `{iodata, screen}`; the returned screen is `current` and should
  be passed back as `previous` on the next diff. The iodata is `[]` when
  no row changed, so callers can skip the terminal write entirely.
  """
  @spec diff(t() | nil, t()) :: {iodata(), t()}
  def diff(nil, current), do: {to_ansi(current), current}

  def diff(%{width: pw, height: ph}, %{width: cw, height: ch} = current)
      when pw != cw or ph != ch do
    {to_ansi(current), current}
  end

  def diff(%{rows: previous_rows}, %{height: height, rows: current_rows} = current) do
    changes =
      Enum.reduce(0..(height - 1), [], fn y, acc ->
        # Equal cell maps render identically (same width in this clause), so
        # an unchanged row costs one map comparison instead of rendering both
        # frames' rows to strings.
        if Map.get(previous_rows, y, %{}) == Map.get(current_rows, y, %{}) do
          acc
        else
          [["\e[", Integer.to_string(y + 1), ";1H\e[2K", render_row(current, y)] | acc]
        end
      end)

    case changes do
      [] -> {[], current}
      changes -> {[Enum.reverse(changes), ScreenStyles.reset()], current}
    end
  end

  @doc """
  Projects the buffer to plain text rows (styles stripped) for assertions.
  """
  @spec to_lines(t()) :: [String.t()]
  def to_lines(%{width: width, height: height, rows: rows}) do
    Enum.map(0..(height - 1), fn y ->
      row = Map.get(rows, y, %{})

      0..(width - 1)
      |> Enum.map(fn x ->
        case Map.get(row, x) do
          {:cont, _style} -> ""
          {grapheme, _style} -> grapheme
          nil -> " "
        end
      end)
      |> Enum.join()
      |> String.trim_trailing()
    end)
  end

  @doc """
  Projects the buffer to per-row ANSI strings for `theme`, preserving styles
  (unlike `to_lines/1`, which strips them). Each row is a self-contained ANSI
  string with a trailing reset and no cursor-move codes, so a browser QA
  harness can parse the SGR runs into coloured spans. Colours resolve through
  the same `render_row` path the live tty uses, so the harness shows exactly
  what the terminal draws.
  """
  @spec to_ansi_lines(t(), :dark | :light) :: [String.t()]
  def to_ansi_lines(%{height: height} = screen, theme) when theme in [:dark, :light] do
    Enum.map(0..(height - 1), fn y -> render_row(screen, y, theme) end)
  end

  defp box_top(w, nil), do: "+" <> String.duplicate("-", w - 2) <> "+"

  defp box_top(w, title) do
    label = " " <> title <> " "
    inner = w - 2

    if String.length(label) + 1 >= inner do
      box_top(w, nil)
    else
      fill = inner - String.length(label) - 1
      "+-" <> label <> String.duplicate("-", fill) <> "+"
    end
  end

  defp draw_sides(screen, x, y, w, h, style) do
    Enum.reduce(1..(h - 2), screen, fn offset, acc ->
      acc
      |> put_text(x, y + offset, "|", style)
      |> put_text(x + w - 1, y + offset, "|", style)
    end)
  end

  defp put_cell(%{rows: rows} = screen, x, y, cell) do
    row = rows |> Map.get(y, %{}) |> Map.put(x, cell)
    %{screen | rows: Map.put(rows, y, row)}
  end

  # Env-theme fast path used by the live tty (to_ansi/1, diff/2): resolve the
  # active theme once per row, then defer to the theme-explicit clause so the
  # colour resolution lives in one place.
  defp render_row(screen, y), do: render_row(screen, y, ScreenStyles.theme())

  defp render_row(%{width: width, rows: rows}, y, theme) do
    row = Map.get(rows, y, %{})

    {segments, last_style} =
      Enum.reduce(0..(width - 1), {[], nil}, fn x, {segments, current_style} ->
        case Map.get(row, x, {" ", :text}) do
          {:cont, _style} ->
            # Second half of a wide glyph: the glyph itself already advanced
            # the terminal two columns, so emit nothing here.
            {segments, current_style}

          {grapheme, style} ->
            if style == current_style do
              {[grapheme | segments], current_style}
            else
              {[grapheme, ScreenStyles.sgr(style, theme) | segments], style}
            end
        end
      end)

    text = segments |> Enum.reverse() |> IO.iodata_to_binary()

    if ScreenStyles.styled?(last_style), do: text <> ScreenStyles.reset(), else: text
  end
end
