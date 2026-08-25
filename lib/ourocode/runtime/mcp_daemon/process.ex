defmodule Ourocode.Runtime.McpDaemon.Process do
  @moduledoc """
  OS process boundary for the local Ouroboros MCP daemon.
  """

  alias Ourocode.Runtime.McpDaemon.Command

  @type spawn_result ::
          {:ok, port(), non_neg_integer() | nil, Path.t()}
          | :unavailable

  @spec spawn_server(String.t(), :inet.port_number(), term()) :: spawn_result()
  def spawn_server(host, port, llm_backend) do
    case Command.build(host, port, llm_backend) do
      {exe, args} ->
        plan = spawn_plan(exe, args, port)

        erl_port =
          Port.open({:spawn_executable, plan.shell}, [
            :binary,
            :exit_status,
            :hide,
            args: plan.args
          ])

        os_pid =
          case Port.info(erl_port, :os_pid) do
            {:os_pid, pid} -> pid
            _none -> nil
          end

        {:ok, erl_port, os_pid, plan.log_path}

      :none ->
        :unavailable
    end
  end

  @doc false
  @spec spawn_plan(String.t(), [String.t()], :inet.port_number(), String.t() | nil) :: map()
  def spawn_plan(exe, args, port, shell \\ nil)
      when is_binary(exe) and is_list(args) and is_integer(port) do
    log_path = Path.join(System.tmp_dir!(), "ourocode-mcp-#{port}.log")
    {command, command_args} = launch_plan(shell, exe, args, log_path)

    %{
      shell: command,
      args: command_args,
      log_path: log_path
    }
  end

  @spec stop(map() | nil) :: :ok
  def stop(%{mode: :spawned} = handle) do
    os_pid = Map.get(handle, :os_pid)
    terminate_os_process(os_pid)

    erl_port = Map.get(handle, :port)
    if is_port(erl_port) and Port.info(erl_port) != nil, do: Port.close(erl_port)
    ensure_process_stopped(os_pid)
    :ok
  rescue
    _exception -> :ok
  end

  def stop(_handle), do: :ok

  defp launch_plan(nil, exe, args, log_path) do
    if windows?() do
      {exe, args}
    else
      shell = default_shell()
      {shell, shell_args(shell, exe, args, log_path)}
    end
  end

  defp launch_plan(shell, exe, args, log_path) do
    if windows?() and windows_shell?(shell) do
      {exe, args}
    else
      {shell, shell_args(shell, exe, args, log_path)}
    end
  end

  defp default_shell do
    System.find_executable("sh") || "/bin/sh"
  end

  defp shell_args(_shell, exe, args, log_path) do
    ["-c", "exec \"$0\" \"$@\" >\"#{log_path}\" 2>&1", exe] ++ args
  end

  defp terminate_os_process(pid) when is_integer(pid) and pid > 0 do
    if windows?() do
      command = System.find_executable("taskkill") || "taskkill"
      System.cmd(command, ["/PID", Integer.to_string(pid), "/T", "/F"], stderr_to_stdout: true)
    else
      System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    :ok
  end

  defp terminate_os_process(_pid), do: :ok

  defp ensure_process_stopped(pid) when is_integer(pid) and pid > 0 do
    if windows?() do
      :ok
    else
      case wait_until_stopped(pid, System.monotonic_time(:millisecond) + 300) do
        :stopped ->
          :ok

        :alive ->
          System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
          wait_until_stopped(pid, System.monotonic_time(:millisecond) + 700)
          :ok
      end
    end
  end

  defp ensure_process_stopped(_pid), do: :ok

  defp wait_until_stopped(pid, deadline) do
    {_output, status} =
      System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

    cond do
      status != 0 -> :stopped
      System.monotonic_time(:millisecond) >= deadline -> :alive
      true ->
        Process.sleep(20)
        wait_until_stopped(pid, deadline)
    end
  end

  defp windows_shell?(shell) do
    shell
    |> Path.basename()
    |> String.downcase()
    |> then(&(&1 in ["cmd", "cmd.exe"]))
  end

  defp windows?, do: match?({:win32, _name}, :os.type())
end
