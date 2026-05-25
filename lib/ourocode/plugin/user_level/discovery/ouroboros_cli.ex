defmodule Ourocode.Plugin.UserLevel.Discovery.OuroborosCLI do
  @moduledoc """
  Discovers installed UserLevel plugins by invoking
  `ouroboros plugin list --json`.

  This adapter is the first-class discovery surface until a dedicated MCP
  plugin-list tool exists. It is read-only: it never installs, trusts, or
  executes plugin code.

  Tests inject a stub runner via the `:command_runner` option so that no
  external process is spawned. The runner contract is
  `runner.(command, args, opts) :: {:ok, %{status: integer, stdout: binary,
  stderr: binary}} | {:error, term()}`.
  """

  @behaviour Ourocode.Plugin.UserLevel.Discovery

  alias Ourocode.Json

  @default_command "ouroboros"
  @default_args ["plugin", "list", "--json"]
  @default_timeout_ms 5_000

  @impl true
  @spec discover(keyword() | map()) :: {:ok, [map()]} | {:error, term()}
  def discover(opts \\ []) do
    opts = if is_map(opts), do: opts, else: Map.new(opts)
    command = Map.get(opts, :command, @default_command)
    args = Map.get(opts, :args, @default_args)
    runner = Map.get(opts, :command_runner, &default_runner/3)
    timeout_ms = Map.get(opts, :timeout_ms, @default_timeout_ms)

    case runner.(command, args, %{timeout_ms: timeout_ms}) do
      {:ok, %{status: 0, stdout: stdout}} ->
        parse(stdout)

      {:ok, %{status: status} = result} when status != 0 ->
        {:error,
         {:ouroboros_cli_failed,
          %{exit_status: status, stderr: Map.get(result, :stderr, "")}}}

      {:ok, other} ->
        {:error, {:ouroboros_cli_unexpected_result, other}}

      {:error, reason} ->
        {:error, {:ouroboros_cli_unavailable, reason}}
    end
  end

  @doc """
  Parses an `ouroboros plugin list --json` payload into the descriptor shape
  expected by `Ourocode.Plugin.UserLevel.Capability.new/1`.

  Public so tests can validate the parser without going through the runner
  indirection.
  """
  @spec parse(binary()) :: {:ok, [map()]} | {:error, term()}
  def parse(stdout) when is_binary(stdout) do
    case Json.decode(stdout) do
      {:ok, %{"plugins" => plugins}} when is_list(plugins) ->
        {:ok, Enum.map(plugins, &normalize_plugin/1)}

      {:ok, plugins} when is_list(plugins) ->
        {:ok, Enum.map(plugins, &normalize_plugin/1)}

      {:ok, _other} ->
        {:error, :ouroboros_cli_unexpected_shape}

      {:error, reason} ->
        {:error, {:ouroboros_cli_invalid_json, reason}}
    end
  end

  defp normalize_plugin(plugin) when is_map(plugin) do
    %{
      plugin_id: read(plugin, ["id", "plugin_id", "name"]),
      plugin_name: read(plugin, ["name", "display_name", "id"]),
      source: :ouroboros_cli,
      version: read(plugin, ["version"]),
      install_scope: normalize_scope(read(plugin, ["install_scope", "scope"])),
      trust_scope:
        plugin
        |> read(["trust_scope", "trust_scopes"], [])
        |> List.wrap()
        |> Enum.filter(&is_binary/1),
      manifest_digest: read(plugin, ["manifest_digest", "digest"]),
      commands:
        plugin
        |> read(["commands"], [])
        |> List.wrap()
        |> Enum.map(&normalize_command/1),
      resolution_origin: %{
        adapter: __MODULE__,
        call: %{command: @default_command, args: @default_args}
      }
    }
  end

  defp normalize_plugin(_other), do: %{plugin_id: nil, source: :ouroboros_cli}

  defp normalize_command(cmd) when is_map(cmd) do
    %{
      name: read(cmd, ["name", "command"]) || "",
      aliases: cmd |> read(["aliases"], []) |> List.wrap() |> Enum.filter(&is_binary/1),
      summary: read(cmd, ["summary", "description"]),
      args:
        cmd
        |> read(["args", "arguments"], [])
        |> List.wrap()
        |> Enum.map(&normalize_arg/1),
      risk_class: read(cmd, ["risk_class", "risk"]),
      expected_artifacts:
        cmd
        |> read(["expected_artifacts", "artifacts"], [])
        |> List.wrap()
        |> Enum.filter(&is_binary/1),
      continuation_hint: read(cmd, ["continuation_hint", "continuation"])
    }
  end

  defp normalize_command(_other), do: %{name: ""}

  defp normalize_arg(arg) when is_map(arg) do
    %{
      name: read(arg, ["name", "arg"]) || "",
      required?: truthy?(read(arg, ["required", "required?"])),
      repeatable?: truthy?(read(arg, ["repeatable", "repeatable?"])),
      description: to_string_safe(read(arg, ["description", "summary"]))
    }
  end

  defp normalize_arg(arg) when is_binary(arg),
    do: %{name: arg, required?: false, repeatable?: false, description: ""}

  defp normalize_arg(_other),
    do: %{name: "", required?: false, repeatable?: false, description: ""}

  defp normalize_scope("user"), do: :user
  defp normalize_scope("workspace"), do: :workspace
  defp normalize_scope("project"), do: :workspace
  defp normalize_scope(_other), do: :unknown

  defp read(map, keys, default \\ nil) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, default, fn key ->
      case Map.get(map, key) do
        nil -> nil
        "" -> nil
        value -> value
      end
    end)
  end

  defp to_string_safe(nil), do: ""
  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: to_string(value)

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_other), do: false

  defp default_runner(command, args, _opts) when is_binary(command) and is_list(args) do
    case System.cmd(command, args, stderr_to_stdout: false) do
      {output, 0} -> {:ok, %{status: 0, stdout: output, stderr: ""}}
      {output, status} -> {:ok, %{status: status, stdout: "", stderr: output}}
    end
  rescue
    error in [ErlangError, File.Error, System.EnvError] ->
      {:error, {:command_runner_raised, Exception.message(error)}}
  end
end
