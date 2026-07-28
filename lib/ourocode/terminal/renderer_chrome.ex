defmodule Ourocode.Terminal.RendererChrome do
  @moduledoc """
  Header, composer, and status bar drawing for the terminal renderer.
  """

  alias Ourocode.Terminal.{HudModel, PromptActivityIndicator, Screen}

  @left 2
  @chip_width 11
  # Braille spinner for the "thinking" state: a smooth rotation reads as live
  # work, where the old .oOo pulse looked like a stutter. Matches the unicode
  # vocabulary already used by the prompt activity frames.
  @spinner ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  # Leading "/command" token in the composer: optional indent, the slash token
  # (slash + a run of non-space), then the rest of the line. Highlighted for
  # the same readability reason as the leading `ooo` token, and only when the
  # slash leads the line so `a/b`, `http://x`, or a mid-line `/x` stay plain.
  @slash_token ~r{^(\s*)(/\S+)(.*)$}

  @spec draw_header(map(), pos_integer(), map(), map()) :: map()
  def draw_header(screen, width, kv, opts) do
    {dot, dot_style} = activity_dot(kv, opts)

    status_word =
      if Map.get(opts, :streaming), do: "thinking", else: Map.get(kv, "status", "starting")

    {auth_text, auth_style} = Map.get(opts, :auth, {"no model  -  /model", :dim})
    auth_col = max(width - String.length(auth_text) - @left, @left)
    status_col = max(auth_col - String.length(status_word) - 4, @left + 20)

    screen
    |> Screen.put_text(@left, 1, "ourocode", :brand)
    |> Screen.put_text(@left + 9, 1, "agent", :dim)
    |> Screen.put_text(status_col, 1, dot, dot_style)
    |> Screen.put_text(status_col + 2, 1, status_word, :dim)
    |> Screen.put_text(auth_col, 1, auth_text, auth_style)
    |> Screen.put_text(@left, 2, "plan, delegate, and verify from one terminal", :dim)
  end

  @spec draw_composer(map(), pos_integer(), integer(), String.t(), atom(), map()) :: map()
  def draw_composer(screen, width, rule_row, prompt_buffer, mode, opts) do
    hud = HudModel.build(%{}, [], mode, opts, width)

    live_activity? = Map.get(opts, :live_turn_activity, []) != []
    prompt_busy? = live_activity? or Map.get(opts, :streaming, false)

    {body_text, body_style} =
      cond do
        prompt_buffer != "" ->
          {prompt_buffer, :text}

        prompt_busy? ->
          {hud.placeholder, :placeholder}

        true ->
          {hud.placeholder, :placeholder}
      end

    marker =
      if prompt_busy? do
        prompt_activity_marker(Map.get(opts, :tick, 0))
      else
        ">"
      end

    chip = chip_text(hud.mode_chip)
    marker_x = @left + @chip_width + 1

    body_x = marker_x + Screen.text_width(marker) + 1

    screen =
      screen
      |> Screen.put_text(@left, rule_row, "", :border)
      |> Screen.put_text(@left, rule_row + 1, chip, :strong)
      |> Screen.put_text(marker_x, rule_row + 1, marker, :accent)

    put_composer_text(
      screen,
      body_x,
      rule_row + 1,
      body_text,
      body_style,
      width - body_x - @left
    )
  end

  @spec draw_status_bar(map(), pos_integer(), integer(), map(), map(), atom(), map()) :: map()
  @spec draw_meta_bar(map(), pos_integer(), integer(), map(), map(), atom(), map()) :: map()
  def draw_meta_bar(screen, width, row, kv, sections, mode, opts) do
    hud = HudModel.build(kv, sections, mode, opts, width)
    session = "session " <> String.replace(hud.left_status, ~r/\s{2,}/, " · ")
    segments = [session | hud.segments]

    screen
    |> draw_segments(@left, row, segments, width - @left * 2)
  end

  def draw_status_bar(screen, width, row, kv, sections, mode, opts) do
    hud = HudModel.build(kv, sections, mode, opts, width)
    hints = hud.actions

    hint_style = if hud.notification != nil, do: :accent, else: :muted
    hint_col = @left

    screen
    |> Screen.put_text(hint_col, row, hints, hint_style)
  end

  defp put_composer_text(screen, x, y, text, :text, width) do
    clipped = clip(text, width)

    cond do
      captures = Regex.run(@slash_token, clipped) ->
        [_full, lead, token, rest] = captures
        put_highlighted_token(screen, x, y, lead, token, :command, rest)

      String.starts_with?(String.trim_leading(clipped), "ooo") ->
        leading = byte_size(clipped) - byte_size(String.trim_leading(clipped))
        lead = binary_part(clipped, 0, leading)
        after_lead = binary_part(clipped, leading, byte_size(clipped) - leading)
        put_highlighted_token(screen, x, y, lead, "ooo", :brand, String.replace_prefix(after_lead, "ooo", ""))

      true ->
        Screen.put_text(screen, x, y, clipped, :text)
    end
  end

  defp put_composer_text(screen, x, y, text, style, width) do
    Screen.put_text(screen, x, y, clip(text, width), style)
  end

  # Paints "<indent :text><token token_style><rest :text>", advancing by
  # display width so multibyte args after the token stay aligned.
  defp put_highlighted_token(screen, x, y, lead, token, token_style, rest) do
    lead_w = Screen.text_width(lead)
    token_w = Screen.text_width(token)

    screen
    |> Screen.put_text(x, y, lead, :text)
    |> Screen.put_text(x + lead_w, y, token, token_style)
    |> Screen.put_text(x + lead_w + token_w, y, rest, :text)
  end

  defp activity_dot(kv, opts) do
    if Map.get(opts, :streaming) do
      {spinner_frame(Map.get(opts, :tick, 0)), :accent}
    else
      health_indicator(kv)
    end
  end

  @doc false
  @spec spinner_frame(non_neg_integer()) :: String.t()
  def spinner_frame(tick), do: Enum.at(@spinner, rem(tick, length(@spinner)))

  defp prompt_activity_marker(tick) do
    PromptActivityIndicator.frame(tick)
  end

  defp health_indicator(kv) do
    case Map.get(kv, "status", "starting") do
      "healthy" -> {"*", :ok}
      "ready" -> {"*", :ok}
      "starting" -> {"*", :warn}
      _other -> {"*", :err}
    end
  end

  defp clip(text, max_width), do: Screen.truncate(text, max_width)

  defp draw_segments(screen, _x, _row, _segments, max_width) when max_width < 10, do: screen

  defp draw_segments(screen, x, row, segments, max_width) when is_list(segments) do
    segments
    |> Enum.reduce_while({screen, x, max_width, 0}, fn segment, {acc, col, left, index} ->
      text = segment_text(segment, left, index)
      width = Screen.text_width(text)

      cond do
        text == "" ->
          {:halt, {acc, col, left, index}}

        width > left ->
          {:halt, {acc, col, left, index}}

        true ->
          style = segment_style(segment, index)
          next_acc = Screen.put_text(acc, col, row, text, style)
          {:cont, {next_acc, col + width, left - width, index + 1}}
      end
    end)
    |> elem(0)
  end

  defp segment_text(segment, left, index) do
    prefix = if index == 0, do: "", else: " "
    raw = prefix <> " " <> segment <> " "

    cond do
      left < 8 -> ""
      Screen.text_width(raw) <= left -> raw
      true -> Screen.truncate(raw, left)
    end
  end

  defp segment_style(segment, 0) do
    cond do
      String.starts_with?(segment, "session ") -> :p_dim
      String.starts_with?(segment, "run ") -> :p_title
      String.starts_with?(segment, "mcp ") -> :p_accent
      String.starts_with?(segment, "Q ") -> :warn
      true -> :p_dim
    end
  end

  defp segment_style(segment, _index) do
    cond do
      String.starts_with?(segment, "session ") -> :p_dim
      String.starts_with?(segment, "mcp ") -> :p_accent
      String.starts_with?(segment, "Q ") -> :warn
      true -> :p_dim
    end
  end

  defp chip_text(chip) do
    label = "[" <> chip <> "]"
    label <> String.duplicate(" ", max(@chip_width - Screen.text_width(label), 0))
  end
end
