defmodule Ourocode.CLI.StartupArgs do
  @moduledoc """
  Parses launch-time arguments for the terminal application.

  Startup arguments configure the terminal bootstrap boundary. Runtime config
  overrides and natural-language task text are handed off to the existing
  config/task parsers after startup-only flags are removed.
  """

  @project_dir_env "OUROCODE_PROJECT_DIR"
  @project_dir_flags MapSet.new(["--project-dir", "--project", "-d"])
  @smoke_test_flags MapSet.new(["--smoke-test", "--smoke", "--verify"])
  @prompt_flags MapSet.new(["--prompt", "-p"])
  @command_flags MapSet.new(["--commands"])
  @format_flags MapSet.new(["--format"])
  @config_flags_with_value MapSet.new([
                             "--parallel-child-count",
                             "--repeat-count",
                             "--allowed-memory-growth-mb",
                             "--stale-cleanup-timeout-ms",
                             "--operation-timeout-ms",
                             "--stream-subscription-cleanup-timeout-ms",
                             "--pane-state-retention-ms",
                             "--cleanup-allowed-memory-growth-mb",
                             "--cleanup-stale-cleanup-timeout-ms",
                             "--cleanup-stream-subscription-cleanup-timeout-ms",
                             "--cleanup-pane-state-retention-ms",
                             "--cleanup-policy.allowed-memory-growth-mb",
                             "--cleanup-policy.stale-cleanup-timeout-ms",
                             "--cleanup-policy.stream-subscription-cleanup-timeout-ms",
                             "--cleanup-policy.pane-state-retention-ms"
                           ])

  @type t :: %{
          required(:project_dir) => String.t(),
          required(:smoke_test?) => boolean(),
          required(:headless?) => boolean(),
          required(:output_format) => :text | :json | :json_debug,
          required(:config_args) => [String.t()],
          required(:task_request) => Ourocode.TaskRequest.t() | nil
        }

  @doc """
  Parses CLI startup arguments.

  Supported startup flags:

    * `--project-dir PATH`
    * `--project-dir=PATH`
    * `--project PATH`
    * `--project=PATH`
    * `-d PATH`
    * `--smoke-test`
    * `--smoke`
    * `--verify`
    * `--commands`
    * `--prompt TEXT`
    * `-p TEXT`
    * `--format text|json|json-debug`

  All recognized startup and config flags are accepted before or after task
  text. Use `--` to force the remaining tokens into the task text.
  """
  @spec parse([String.t()], keyword() | map()) :: {:ok, t()} | {:error, String.t()}
  def parse(args, options \\ [])

  def parse(args, options) when is_list(args) do
    with {:ok, {project_dir, smoke_test?, headless?, output_format, remaining_args}} <-
           extract_startup_args(args, default_project_dir()),
         {:ok, parsed_args} <- Ourocode.TaskRequest.parse_cli_args(remaining_args, options) do
      headless? =
        headless? or
          (output_format in [:json, :json_debug] and not is_nil(parsed_args.task_request))

      {:ok,
       %{
         project_dir: project_dir,
         smoke_test?: smoke_test?,
         headless?: headless?,
         output_format: output_format,
         config_args: parsed_args.config_args,
         task_request: parsed_args.task_request
       }}
    end
  end

  def parse(_args, _options), do: {:error, "CLI args must be a list"}

  @doc """
  Returns the default project directory for the launcher.

  Resolution order:

    * the `OUROCODE_PROJECT_DIR` environment variable when it is set to a
      non-empty value (expanded to an absolute path), otherwise
    * the current working directory.

  This keeps the documented `ourocode` (no `--project-dir`) quick-start working
  on any machine instead of pointing at a build-time developer path.
  """
  @spec default_project_dir() :: String.t()
  def default_project_dir do
    case System.get_env(@project_dir_env) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> File.cwd!()
          trimmed -> Path.expand(trimmed)
        end

      _ ->
        File.cwd!()
    end
  end

  defp extract_startup_args(args, project_dir),
    do: extract_startup_args(args, project_dir, false, false, :text, [], [])

  defp extract_startup_args(
         [],
         project_dir,
         smoke_test?,
         headless?,
         output_format,
         prompt_args,
         kept_args
       ) do
    {:ok,
     {project_dir, smoke_test?, headless?, output_format, Enum.reverse(kept_args) ++ prompt_args}}
  end

  defp extract_startup_args(
         ["--" | task_args],
         project_dir,
         smoke_test?,
         headless?,
         output_format,
         prompt_args,
         kept_args
       ) do
    {:ok,
     {project_dir, smoke_test?, headless?, output_format,
      Enum.reverse(kept_args) ++ prompt_args ++ task_args}}
  end

  defp extract_startup_args(
         [arg | rest],
         project_dir,
         smoke_test?,
         headless?,
         output_format,
         prompt_args,
         kept_args
       )
       when is_binary(arg) do
    cond do
      project_dir_assignment?(arg) ->
        [flag, value] = String.split(arg, "=", parts: 2)

        consume_project_dir(
          flag,
          value,
          rest,
          smoke_test?,
          headless?,
          output_format,
          prompt_args,
          kept_args
        )

      format_assignment?(arg) ->
        [_flag, value] = String.split(arg, "=", parts: 2)
        consume_format(value, rest, project_dir, smoke_test?, headless?, prompt_args, kept_args)

      MapSet.member?(@project_dir_flags, arg) ->
        case rest do
          [value | tail] when is_binary(value) ->
            consume_project_dir(
              arg,
              value,
              tail,
              smoke_test?,
              headless?,
              output_format,
              prompt_args,
              kept_args
            )

          [] ->
            {:error, "missing value for startup argument: #{arg}"}

          [value | _tail] ->
            {:error, "startup argument #{arg} expects a string value, got: #{inspect(value)}"}
        end

      MapSet.member?(@smoke_test_flags, arg) ->
        extract_startup_args(
          rest,
          project_dir,
          true,
          headless?,
          output_format,
          prompt_args,
          kept_args
        )

      MapSet.member?(@prompt_flags, arg) ->
        consume_prompt(arg, rest, project_dir, smoke_test?, output_format, prompt_args, kept_args)

      MapSet.member?(@command_flags, arg) ->
        extract_startup_args(
          rest,
          project_dir,
          smoke_test?,
          true,
          output_format,
          prompt_args ++ ["/commands"],
          kept_args
        )

      MapSet.member?(@format_flags, arg) ->
        consume_format_arg(arg, rest, project_dir, smoke_test?, headless?, prompt_args, kept_args)

      MapSet.member?(@config_flags_with_value, arg) ->
        preserve_config_value(
          arg,
          rest,
          project_dir,
          smoke_test?,
          headless?,
          output_format,
          prompt_args,
          kept_args
        )

      String.starts_with?(arg, "--") ->
        extract_startup_args(
          rest,
          project_dir,
          smoke_test?,
          headless?,
          output_format,
          prompt_args,
          [
            arg | kept_args
          ]
        )

      true ->
        extract_startup_args(
          rest,
          project_dir,
          smoke_test?,
          headless?,
          output_format,
          prompt_args,
          [arg | kept_args]
        )
    end
  end

  defp extract_startup_args(
         [arg | _rest],
         _project_dir,
         _smoke_test?,
         _headless?,
         _output_format,
         _prompt_args,
         _kept_args
       ) do
    {:error, "CLI args must be strings, got: #{inspect(arg)}"}
  end

  defp project_dir_assignment?(arg) do
    case String.split(arg, "=", parts: 2) do
      [flag, _value] -> MapSet.member?(@project_dir_flags, flag)
      _other -> false
    end
  end

  defp format_assignment?(arg) do
    case String.split(arg, "=", parts: 2) do
      [flag, _value] -> MapSet.member?(@format_flags, flag)
      _other -> false
    end
  end

  defp consume_project_dir(
         flag,
         value,
         rest,
         smoke_test?,
         headless?,
         output_format,
         prompt_args,
         kept_args
       ) do
    value = String.trim(value)

    if value == "" or String.starts_with?(value, "--") do
      {:error, "missing value for startup argument: #{flag}"}
    else
      extract_startup_args(
        rest,
        Path.expand(value),
        smoke_test?,
        headless?,
        output_format,
        prompt_args,
        kept_args
      )
    end
  end

  defp consume_prompt(
         flag,
         [value | rest],
         project_dir,
         smoke_test?,
         output_format,
         prompt_args,
         kept_args
       )
       when is_binary(value) do
    if String.trim(value) == "" or String.starts_with?(value, "--") do
      {:error, "missing value for startup argument: #{flag}"}
    else
      extract_startup_args(
        rest,
        project_dir,
        smoke_test?,
        true,
        output_format,
        prompt_args ++ [value],
        kept_args
      )
    end
  end

  defp consume_prompt(
         flag,
         [],
         _project_dir,
         _smoke_test?,
         _output_format,
         _prompt_args,
         _kept_args
       ) do
    {:error, "missing value for startup argument: #{flag}"}
  end

  defp consume_prompt(
         flag,
         [value | _rest],
         _project_dir,
         _smoke_test?,
         _output_format,
         _prompt_args,
         _kept_args
       ) do
    {:error, "startup argument #{flag} expects a string value, got: #{inspect(value)}"}
  end

  defp consume_format_arg(
         flag,
         [value | rest],
         project_dir,
         smoke_test?,
         headless?,
         prompt_args,
         kept_args
       )
       when is_binary(value) do
    consume_format(value, rest, project_dir, smoke_test?, headless?, prompt_args, kept_args, flag)
  end

  defp consume_format_arg(
         flag,
         [],
         _project_dir,
         _smoke_test?,
         _headless?,
         _prompt_args,
         _kept_args
       ) do
    {:error, "missing value for startup argument: #{flag}"}
  end

  defp consume_format_arg(
         flag,
         [value | _rest],
         _project_dir,
         _smoke_test?,
         _headless?,
         _prompt_args,
         _kept_args
       ) do
    {:error, "startup argument #{flag} expects a string value, got: #{inspect(value)}"}
  end

  defp consume_format(
         value,
         rest,
         project_dir,
         smoke_test?,
         headless?,
         prompt_args,
         kept_args,
         flag \\ "--format"
       ) do
    case String.downcase(String.trim(value)) do
      "text" ->
        extract_startup_args(
          rest,
          project_dir,
          smoke_test?,
          headless?,
          :text,
          prompt_args,
          kept_args
        )

      "json" ->
        extract_startup_args(
          rest,
          project_dir,
          smoke_test?,
          headless?,
          :json,
          prompt_args,
          kept_args
        )

      "json-debug" ->
        extract_startup_args(
          rest,
          project_dir,
          smoke_test?,
          headless?,
          :json_debug,
          prompt_args,
          kept_args
        )

      _other ->
        {:error, "unsupported value for #{flag}: #{value} (expected text, json, or json-debug)"}
    end
  end

  defp preserve_config_value(
         arg,
         [value | rest],
         project_dir,
         smoke_test?,
         headless?,
         output_format,
         prompt_args,
         kept_args
       )
       when is_binary(value) do
    extract_startup_args(rest, project_dir, smoke_test?, headless?, output_format, prompt_args, [
      value,
      arg | kept_args
    ])
  end

  defp preserve_config_value(
         arg,
         [],
         _project_dir,
         _smoke_test?,
         _headless?,
         _output_format,
         _prompt_args,
         _kept_args
       ) do
    {:error, "missing value for config override argument: #{arg}"}
  end

  defp preserve_config_value(
         arg,
         [value | _rest],
         _project_dir,
         _smoke_test?,
         _headless?,
         _output_format,
         _prompt_args,
         _kept_args
       ) do
    {:error, "config override argument #{arg} expects a string value, got: #{inspect(value)}"}
  end
end
