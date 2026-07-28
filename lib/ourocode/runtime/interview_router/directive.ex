defmodule Ourocode.Runtime.InterviewRouter.Directive do
  @moduledoc """
  Parser for the constrained interview-router text protocol.
  """

  @type option :: %{label: String.t(), description: String.t()}
  @type t ::
          {:answer, String.t()}
          | {:ask_user, String.t(), [option()]}
          | {:tool, atom(), String.t()}
          | :unparseable

  @option_re ~r/\A[-*]\s*(.+?)\s*[|｜]\s*(.+)\z/u
  @directive_re ~r/\A(?:TOOL\s+(?:READ|GLOB|GREP)\b|ANSWER\b|ASK_USER\b)/

  @spec parse(String.t()) :: t()
  def parse(text) when is_binary(text) do
    {line, directive_text} = first_directive_segment(text)

    cond do
      match = Regex.run(~r/\ATOOL\s+READ\s+(.+)\z/s, line) ->
        {:tool, :read, String.trim(Enum.at(match, 1))}

      match = Regex.run(~r/\ATOOL\s+GLOB\s+(.+)\z/s, line) ->
        {:tool, :glob, String.trim(Enum.at(match, 1))}

      match = Regex.run(~r/\ATOOL\s+GREP\s+(.+)\z/s, line) ->
        {:tool, :grep, String.trim(Enum.at(match, 1))}

      String.match?(line, ~r/\AANSWER\b/) ->
        {:answer, payload_after(directive_text, line, "ANSWER")}

      String.match?(line, ~r/\AASK_USER\b/) ->
        parse_ask_user(payload_after(directive_text, line, "ASK_USER"))

      true ->
        :unparseable
    end
  end

  def parse(_text), do: :unparseable

  # ASK_USER body = a question, optionally followed by up to 4 suggested
  # option lines `- <label> | <description>`. The options let the loop
  # present it as a wonderTool checkpoint (SKILL PATH 2 "with suggested
  # options"); 0 options is valid (the caller pads to the wonderTool minimum).
  defp parse_ask_user(body) do
    lines =
      body
      |> expand_inline_ask_user_options()
      |> String.split("\n")

    {opt_lines, q_lines} = Enum.split_with(lines, &Regex.match?(@option_re, String.trim(&1)))

    options =
      opt_lines
      |> Enum.map(fn l ->
        [_, label, desc] = Regex.run(@option_re, String.trim(l))
        %{label: String.trim(label), description: String.trim(desc)}
      end)
      |> Enum.take(4)

    prompt =
      q_lines
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
      |> String.trim()

    {:ask_user, prompt, options}
  end

  defp expand_inline_ask_user_options(body) do
    lines = String.split(body, "\n")

    if length(lines) == 1 do
      expand_inline_ask_user_option_line(body)
    else
      body
    end
  end

  defp expand_inline_ask_user_option_line(body) do
    case Regex.run(~r/\s+-\s+[^|｜\n]+?\s*[|｜]/u, body, return: :index) do
      [{start, _length}] ->
        {question, rest} = String.split_at(body, start)
        option_lines = inline_option_lines(rest)

        if option_lines == [] do
          body
        else
          ([String.trim(question)] ++ option_lines)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("\n")
        end

      _no_inline_options ->
        body
    end
  end

  defp inline_option_lines(rest) do
    ~r/(?:^\s*-\s*|\s+-\s*)([^|｜\n]+?)\s*[|｜]\s*(.*?)(?=\s+-\s*[^|｜\n]+?\s*[|｜]|$)/u
    |> Regex.scan(rest)
    |> Enum.map(fn [_, label, desc] ->
      "- #{String.trim(label)} | #{String.trim(desc)}"
    end)
    |> Enum.reject(&(&1 == "-  |"))
  end

  # The model is told to emit the directive first, but some CLI wrappers
  # prepend runner banners to stdout (Codex CLI prints a provider label and
  # appends a `tokens used` footer). Scan to the first directive and discard
  # known footers so strict routing survives real provider wrappers without
  # accepting arbitrary prose as a decision.
  defp first_directive_segment(text) do
    lines =
      text
      |> strip_echoed_prompt()
      |> String.split("\n", trim: false)

    case Enum.find_index(lines, &(String.trim(&1) =~ @directive_re)) do
      nil ->
        {"", ""}

      index ->
        segment_lines =
          lines
          |> Enum.drop(index)
          |> Enum.take_while(&(not cli_footer_line?(&1)))

        line =
          segment_lines
          |> Enum.map(&String.trim/1)
          |> Enum.find("", &(&1 != ""))

        {line, Enum.join(segment_lines, "\n")}
    end
  end

  defp strip_echoed_prompt(text) do
    case Regex.split(~r/^\s*## Your reply\s*$/m, text, parts: 2) do
      [_before, after_marker] -> after_marker
      _no_marker -> text
    end
  end

  defp cli_footer_line?(line) do
    String.trim(line) in ["tokens used"]
  end

  defp payload_after(full_text, first_line, keyword) do
    rest_of_first = String.replace_prefix(first_line, keyword, "") |> String.trim_leading()

    tail =
      case String.split(full_text, "\n", parts: 2) do
        [_only] -> ""
        [_first, rest] -> rest
      end
      |> String.trim_trailing()

    [rest_of_first, tail]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> String.trim()
  end
end
