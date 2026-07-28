defmodule Ourocode.Terminal.RendererChromeTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{RendererChrome, Screen, ScreenStyles}

  test "spinner_frame cycles through the braille rotation" do
    assert RendererChrome.spinner_frame(0) == "⠋"
    assert RendererChrome.spinner_frame(1) == "⠙"
    assert RendererChrome.spinner_frame(10) == "⠋"
    assert Screen.text_width(RendererChrome.spinner_frame(3)) == 1
  end

  test "the thinking state shows the spinner instead of the status word's dot" do
    lines =
      90
      |> Screen.new(4)
      |> RendererChrome.draw_header(90, %{"status" => "healthy"}, %{streaming: true, tick: 2})
      |> Screen.to_lines()

    text = Enum.join(lines, "\n")
    assert text =~ "thinking"
    assert text =~ RendererChrome.spinner_frame(2)
  end

  test "draw_header uses product-facing subtitle" do
    lines =
      90
      |> Screen.new(4)
      |> RendererChrome.draw_header(90, %{"status" => "healthy"}, %{
        auth: {"model: codex  (ChatGPT)", :ok}
      })
      |> Screen.to_lines()

    text = Enum.join(lines, "\n")

    assert text =~ "plan, delegate, and verify from one terminal"
    refute text =~ "interactive baseline"
  end

  test "draw_composer uses prompt text and highlights ooo token through rendered text" do
    lines =
      60
      |> Screen.new(8)
      |> RendererChrome.draw_composer(60, 4, "ooo interview", :normal, %{})
      |> Screen.to_lines()

    text = Enum.join(lines, "\n")

    assert text =~ "> ooo interview"
    refute text =~ "Message ourocode"
  end

  defp composer_ansi(buffer, theme) do
    60
    |> Screen.new(8)
    |> RendererChrome.draw_composer(60, 4, buffer, :normal, %{})
    |> Screen.to_ansi_lines(theme)
    |> Enum.join("\n")
  end

  test "draw_composer highlights a leading /command token with the command style" do
    ansi = composer_ansi("/help", :dark)

    assert ansi =~ ScreenStyles.sgr(:command, :dark) <> "/help"
  end

  test "the /command token highlight adapts to the theme" do
    dark = composer_ansi("/model", :dark)
    light = composer_ansi("/model", :light)

    assert dark =~ ScreenStyles.sgr(:command, :dark) <> "/model"
    assert light =~ ScreenStyles.sgr(:command, :light) <> "/model"
    refute ScreenStyles.sgr(:command, :dark) == ScreenStyles.sgr(:command, :light)
  end

  test "only the leading /command token is highlighted; args stay plain" do
    ansi = composer_ansi("/preflight ls -la", :dark)

    assert ansi =~ ScreenStyles.sgr(:command, :dark) <> "/preflight"
    # Exactly one command-styled run — the token, never the args.
    assert ansi |> String.split(ScreenStyles.sgr(:command, :dark)) |> length() == 2
  end

  test "a mid-line or non-command slash is not highlighted" do
    for buffer <- ["a/b", "http://example.com", "run /x", "hello world"] do
      refute composer_ansi(buffer, :dark) =~ ScreenStyles.sgr(:command, :dark)
    end
  end

  test "the ooo token keeps its brand highlight and is distinct from /command" do
    ansi = composer_ansi("ooo interview", :dark)

    assert ansi =~ ScreenStyles.sgr(:brand, :dark) <> "ooo"
    refute ansi =~ ScreenStyles.sgr(:command, :dark)
  end

  test "draw_composer renders the reverse-i-search line with the query and match" do
    text =
      60
      |> Screen.new(8)
      |> RendererChrome.draw_composer(60, 4, "", :search, %{
        search: %{query: "pm", match: "ooo pm design"}
      })
      |> Screen.to_lines()
      |> Enum.join("\n")

    assert text =~ "(reverse-i-search)`pm`: ooo pm design"
  end

  test "draw_composer shows (no match) when reverse-i-search has no hit" do
    text =
      60
      |> Screen.new(8)
      |> RendererChrome.draw_composer(60, 4, "", :search, %{search: %{query: "zzz", match: nil}})
      |> Screen.to_lines()
      |> Enum.join("\n")

    assert text =~ "(reverse-i-search)`zzz`: (no match)"
  end

  test "draw_composer uses richer entry placeholder on narrow terminals" do
    text =
      60
      |> Screen.new(8)
      |> RendererChrome.draw_composer(60, 4, "", :normal, %{})
      |> Screen.to_lines()
      |> Enum.join("\n")

    assert text =~ "[main]"
    assert text =~ "Ask, / command, or ooo auto/pm/run"
    refute text =~ "ooo starts structure"
  end

  test "draw_status_bar surfaces notification over default hints" do
    sections = %{}
    kv = %{"runtime" => "ready", "transports" => "stdio,sse,streamable_http"}

    lines =
      80
      |> Screen.new(4)
      |> RendererChrome.draw_status_bar(80, 3, kv, sections, :normal, %{
        notifications: ["Esc again to clear input"]
      })
      |> Screen.to_lines()

    text = Enum.join(lines, "\n")

    assert text =~ "Esc again to clear input"
    refute text =~ "^C  exit"
  end

  test "draw_meta_bar surfaces runtime metadata when the app is healthy" do
    lines =
      80
      |> Screen.new(4)
      |> RendererChrome.draw_meta_bar(
        80,
        3,
        %{"runtime" => "unknown", "status" => "healthy", "transports" => "none"},
        %{},
        :normal,
        %{}
      )
      |> Screen.to_lines()

    text = Enum.join(lines, "\n")

    assert text =~ "ready"
    assert text =~ "session"
    refute text =~ "offline"
  end

  test "draw_meta_bar uses local instead of offline for an active terminal without transports" do
    lines =
      80
      |> Screen.new(4)
      |> RendererChrome.draw_meta_bar(
        80,
        3,
        %{"runtime" => "?", "transports" => "none"},
        %{},
        :normal,
        %{}
      )
      |> Screen.to_lines()

    text = Enum.join(lines, "\n")

    assert text =~ "main"
    refute text =~ "?"
    refute text =~ "offline"
  end
end
