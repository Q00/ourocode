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
    handle
    |> Map.get(:os_pid)
    |> terminate_os_process()

    erl_port = Map.get(handle, :port)
    if is_port(erl_port) and Port.info(erl_port) != nil, do: Port.close(erl_port)
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

  defp windows_shell?(shell) do
    shell
    |> Path.basename()
    |> String.downcase()
    |> then(&(&1 in ["cmd", "cmd.exe"]))
  end

  defp windows?, do: match?({:win32, _name}, :os.type())
end
