defmodule Ourocode.Terminal.FileDiscovery do
  @moduledoc """
  Discovers project files for `@file` mention suggestions.
  """

  @limit 1_000

  @spec discover(keyword()) :: [String.t()]
  def discover(opts \\ []) do
    finder = Keyword.get(opts, :find_executable, &System.find_executable/1)
    runner = Keyword.get(opts, :cmd, &System.cmd/3)
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    case finder.("rg") do
      nil ->
        []

      _rg ->
        case runner.("rg", ["--files"], cd: cwd, stderr_to_stdout: true) do
          {out, 0} -> parse_rg_files(out)
          _other -> []
        end
    end
  rescue
    _exception -> []
  end

  @spec parse_rg_files(String.t()) :: [String.t()]
  def parse_rg_files(out) when is_binary(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim_trailing(&1, "\r"))
    |> Enum.reject(&ignored_path?/1)
    |> Enum.take(@limit)
  end

  @spec ignored_path?(String.t()) :: boolean()
  def ignored_path?(path) when is_binary(path) do
    String.starts_with?(path, ["_build/", "deps/", ".git/"]) or
      String.contains?(path, ["/_build/", "/deps/", "/.git/"])
  end
end
