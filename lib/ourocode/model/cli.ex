defmodule Ourocode.Model.Cli do
  @moduledoc """
  Streams a turn through a locally-installed CLI backend.

  Agent CLIs such as Claude and Codex are deliberately excluded: spawning
  them per turn is too slow for ourocode's interactive path. Direct API
  transports own those providers.
  """

  @bins %{gemini: "gemini"}

  # Replay-safe retry only: a CLI that exits non-zero before emitting any
  # chunk can be relaunched without the user seeing duplicate output. Once a
  # chunk has reached the renderer — or the run timed out after streaming —
  # the failure surfaces immediately.
  @max_attempts 3
  @retry_base_delay_ms 1_000

  @doc "Known CLI backend ids keyed to their binary name."
  @spec specs() :: %{atom() => String.t()}
  def specs, do: @bins

  @doc """
  Non-interactive argv for a one-shot prompt, per CLI.
  """
  @spec args(atom(), String.t(), String.t() | nil) :: [String.t()]
  def args(id, prompt, system \\ nil)

  def args(:gemini, prompt, _system), do: ["-p", prompt]

  @doc "Absolute path of a CLI backend's binary, or nil if not installed."
  @spec resolve(atom(), (String.t() -> String.t() | nil)) :: String.t() | nil
  def resolve(id, which) when is_function(which, 1) do
    case Map.fetch(@bins, id) do
      {:ok, bin} -> which.(bin)
      :error -> nil
    end
  end

  @doc false
  @spec runner_command(
          String.t(),
          [String.t()],
          {:unix | :win32, atom()},
          (String.t() -> String.t() | nil)
        ) :: {String.t(), [String.t()]}
  def runner_command(path, args, os_type \\ :os.type(), which \\ &System.find_executable/1)

  def runner_command(path, args, {:win32, _name}, _which), do: {path, args}

  def runner_command(path, args, _os_type, which) when is_function(which, 1) do
    {which.("sh") || "/bin/sh", ["-c", ~s(exec "$0" "$@" </dev/null), path | args]}
  end

  @doc """
  Runs the CLI for one prompt, invoking `on_chunk` for each stdout chunk.

  Returns `{:ok, full_text}` on a clean exit, `{:error, {:exit, status}}`
  otherwise.
  """
  @spec stream(atom(), String.t(), keyword(), (String.t() -> any())) ::
          {:ok, String.t()} | {:error, term()}
  def stream(id, prompt, opts, on_chunk) when is_binary(prompt) and is_function(on_chunk, 1) do
    which = Keyword.get(opts, :which, &System.find_executable/1)
    run = Keyword.get(opts, :run, &run/4)
    bin = Map.fetch!(@bins, id)

    case which.(bin) do
      nil ->
        {:error, {:not_installed, bin}}

      path ->
        delay = Keyword.get(opts, :retry_base_delay_ms, @retry_base_delay_ms)
        run_with_retry(id, path, args(id, prompt, nil), on_chunk, delay, 1, run)
    end
  end

  defp run_with_retry(id, path, args, on_chunk, delay, attempt, run) do
    emitted = :counters.new(1, [])

    counted_chunk = fn chunk ->
      :counters.add(emitted, 1, 1)
      on_chunk.(chunk)
    end

    case run.(id, path, args, counted_chunk) do
      {:error, {:exit, _status}} = error ->
        if :counters.get(emitted, 1) == 0 and attempt < @max_attempts do
          Process.sleep(delay * Integer.pow(2, attempt - 1))
          run_with_retry(id, path, args, on_chunk, delay, attempt + 1, run)
        else
          error
        end

      other ->
        other
    end
  end

  defp run(id, path, args, on_chunk) do
    {command, command_args} = runner_command(path, args)

    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        args: command_args
      ])

    collect(id, port, [], "", on_chunk)
  end

  defp collect(id, port, acc, partial, on_chunk) do
    receive do
      {^port, {:data, data}} ->
        {acc, partial} = handle_output(id, partial <> data, acc, on_chunk)
        collect(id, port, acc, partial, on_chunk)

      {^port, {:exit_status, 0}} ->
        {acc, _partial} = flush_output(id, partial, acc, on_chunk)
        {:ok, final_text(id, acc)}

      {^port, {:exit_status, status}} ->
        {:error, {:exit, status}}
    after
      180_000 ->
        safe_close(port)
        {:error, :timeout}
    end
  end

  defp handle_output(_id, data, acc, on_chunk) do
    on_chunk.(data)
    {[data | acc], ""}
  end

  defp flush_output(_id, partial, acc, on_chunk) do
    if partial != "" do
      on_chunk.(partial)
      {[partial | acc], ""}
    else
      {acc, ""}
    end
  end

  defp final_text(_id, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp safe_close(port) do
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end
end
