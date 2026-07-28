defmodule Ourocode.Terminal.FrameSections do
  @moduledoc """
  Parses shell-rendered frame sections into renderer-friendly summaries.
  """

  @spec parse(String.t()) :: [{String.t(), [String.t()]}]
  def parse(frame) when is_binary(frame) do
    frame
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing(&1, "\r"))
    |> Enum.reduce({[], nil}, fn line, {sections, current} ->
      cond do
        String.starts_with?(line, "+-- ") ->
          sections = flush_section(sections, current)
          {sections, {section_title(line), []}}

        line == "+--" ->
          {flush_section(sections, current), nil}

        String.starts_with?(line, "| ") and current != nil ->
          {title, body} = current
          content = String.trim_leading(line, "| ")

          if region_marker?(content) do
            {sections, current}
          else
            {sections, {title, [content | body]}}
          end

        true ->
          {sections, current}
      end
    end)
    |> then(fn {sections, current} -> flush_section(sections, current) end)
    |> Enum.reverse()
  end

  def parse(_frame), do: []

  @spec body([{String.t(), [String.t()]}], String.t()) :: [String.t()]
  def body(sections, prefix) do
    Enum.find_value(sections, [], fn {title, section_body} ->
      if String.starts_with?(title, prefix), do: section_body, else: nil
    end)
  end

  @spec status_fields([{String.t(), [String.t()]}]) :: map()
  def status_fields(sections) do
    ["ourocode terminal", "State"]
    |> Enum.flat_map(&body(sections, &1))
    |> Enum.flat_map(&String.split(&1, " ", trim: true))
    |> Enum.reduce(%{}, fn token, acc ->
      case String.split(token, "=", parts: 2) do
        [k, v] when v != "" -> Map.put_new(acc, String.trim_trailing(k, "?"), v)
        _ -> acc
      end
    end)
  end

  @spec session_count([{String.t(), [String.t()]}]) :: non_neg_integer()
  def session_count(sections) do
    sections
    |> body("Parent/Child Sessions")
    |> Enum.count(&(&1 not in ["parent empty", "child empty", ""] and not region_marker?(&1)))
  end

  @spec plugin_count([{String.t(), [String.t()]}]) :: non_neg_integer()
  def plugin_count(sections) do
    sections
    |> body("Plugin Status")
    |> Enum.count(&(&1 not in ["empty", ""] and not String.starts_with?(&1, "status=")))
  end

  defp flush_section(sections, nil), do: sections

  defp flush_section(sections, {title, section_body}) do
    [{title, Enum.reverse(section_body)} | sections]
  end

  defp section_title(line) do
    line
    |> String.trim_leading("+-- ")
    |> String.split(" region=", parts: 2)
    |> List.first()
    |> String.split(" x=", parts: 2)
    |> List.first()
    |> String.trim()
  end

  defp region_marker?(content) do
    Regex.match?(~r/^\[[a-z-]+-region\]\s+x=\d/, content)
  end
end
