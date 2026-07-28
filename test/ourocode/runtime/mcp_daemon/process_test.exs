defmodule Ourocode.Runtime.McpDaemon.ProcessTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.McpDaemon.Process, as: DaemonProcess

  test "spawn_plan redirects daemon output to a per-port log without shell quoting args" do
    plan =
      DaemonProcess.spawn_plan(
        "/bin/ouroboros",
        ["mcp", "serve", "--port", "4321"],
        4321,
        "/bin/sh"
      )

    assert plan.shell == "/bin/sh"
    assert plan.log_path == Path.join(System.tmp_dir!(), "ourocode-mcp-4321.log")

    assert plan.args == [
             "-c",
             "exec \"$0\" \"$@\" >\"#{plan.log_path}\" 2>&1",
             "/bin/ouroboros",
             "mcp",
             "serve",
             "--port",
             "4321"
           ]
  end

  test "spawn_plan uses direct executable invocation for default Windows launches" do
    exe = "C:\\Program Files\\Ouroboros\\ouroboros.exe"
    args = ["mcp", "serve", "--port", "4322"]

    plan =
      DaemonProcess.spawn_plan(
        exe,
        args,
        4322
      )

    if windows?() do
      assert plan.shell == exe
      assert plan.args == args
    else
      assert plan.shell == (System.find_executable("sh") || "/bin/sh")

      assert plan.args == [
               "-c",
               "exec \"$0\" \"$@\" >\"#{plan.log_path}\" 2>&1",
               "C:\\Program Files\\Ouroboros\\ouroboros.exe",
               "mcp",
               "serve",
               "--port",
               "4322"
             ]
    end
  end

  test "spawn_plan executes a real Windows executable path containing spaces" do
    if windows?() do
      exe = "C:\\Program Files\\Git\\bin\\bash.exe"
      assert File.exists?(exe)

      plan = DaemonProcess.spawn_plan(exe, ["-lc", "printf spawn_plan_exec_ok"], 4323)
      File.rm(plan.log_path)

      {status, output} = run_spawn_plan(plan)
      log_output = if File.exists?(plan.log_path), do: File.read!(plan.log_path), else: ""

      assert status == 0
      assert output <> log_output == "spawn_plan_exec_ok"
    end
  after
    File.rm(Path.join(System.tmp_dir!(), "ourocode-mcp-4323.log"))
  end

  test "spawn_plan does not route explicit Windows cmd shell through broken command string" do
    if windows?() do
      exe = "C:\\Program Files\\Git\\bin\\bash.exe"
      shell = "C:\\Windows\\System32\\cmd.exe"
      assert File.exists?(exe)
      assert File.exists?(shell)

      plan = DaemonProcess.spawn_plan(exe, ["-lc", "printf cmd_spawn_ok"], 54322, shell)
      File.rm(plan.log_path)

      assert plan.shell == exe
      assert plan.args == ["-lc", "printf cmd_spawn_ok"]

      {status, output} = run_spawn_plan(plan)
      log_output = if File.exists?(plan.log_path), do: File.read!(plan.log_path), else: ""

      assert status == 0
      assert output <> log_output == "cmd_spawn_ok"
    end
  after
    File.rm(Path.join(System.tmp_dir!(), "ourocode-mcp-54322.log"))
  end

  test "stop is a safe no-op for non-spawned handles" do
    assert :ok == DaemonProcess.stop(nil)
    assert :ok == DaemonProcess.stop(%{mode: :external, url: "http://x/mcp"})
    assert :ok == DaemonProcess.stop(%{mode: :disabled, url: "http://x/mcp"})
  end

  test "stop reaps a spawned OS process" do
    command = System.find_executable("erl")
    assert is_binary(command)

    erl_port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        :hide,
        args: ["-noshell", "-eval", "timer:sleep(infinity)."]
      ])

    {:os_pid, os_pid} = Port.info(erl_port, :os_pid)
    assert os_process_alive?(os_pid)

    assert :ok == DaemonProcess.stop(%{mode: :spawned, port: erl_port, os_pid: os_pid, url: "u"})

    refute_os_process_alive(os_pid)
  end

  defp refute_os_process_alive(os_pid) do
    deadline = System.monotonic_time(:millisecond) + 1_500

    unless wait_until_dead(os_pid, deadline) do
      flunk("expected spawned OS process #{os_pid} to be reaped")
    end
  end

  defp wait_until_dead(os_pid, deadline) do
    cond do
      not os_process_alive?(os_pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(25)
        wait_until_dead(os_pid, deadline)
    end
  end

  defp os_process_alive?(os_pid) when is_integer(os_pid) and os_pid > 0 do
    if windows?() do
      tasklist_contains_pid?(os_pid)
    else
      {_output, code} =
        System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

      code == 0
    end
  end

  defp tasklist_contains_pid?(os_pid) do
    {output, _code} =
      System.cmd("tasklist", ["/FI", "PID eq #{os_pid}", "/NH"], stderr_to_stdout: true)

    output
    |> String.split()
    |> Enum.member?(Integer.to_string(os_pid))
  end

  defp run_spawn_plan(plan) do
    port =
      Port.open({:spawn_executable, plan.shell}, [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        args: plan.args
      ])

    collect_port(port, [])
  end

  defp collect_port(port, chunks) do
    receive do
      {^port, {:data, data}} ->
        collect_port(port, [data | chunks])

      {^port, {:exit_status, status}} ->
        {status, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    after
      2_000 ->
        flunk("spawn_plan did not exit")
    end
  end

  defp windows?, do: match?({:win32, _name}, :os.type())
end
