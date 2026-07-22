defmodule Ourocode.Runtime.McpDaemonTest do
  @moduledoc """
  Deterministic coverage for the conservative launch contract. These tests
  never spawn the real server (no `uvx`/network in CI) — they exercise the
  decision branches that must keep the app working when the daemon cannot or
  should not start.
  """

  use ExUnit.Case, async: false

  alias Ourocode.Runtime.McpDaemon
  alias Ourocode.Test.PortPrograms

  import Ourocode.Test.OsProcessAssertions

  setup do
    saved = {System.get_env("OUROCODE_MCP_AUTOSTART"), System.get_env("OUROCODE_MCP_URL")}

    on_exit(fn ->
      {auto, url} = saved
      restore("OUROCODE_MCP_AUTOSTART", auto)
      restore("OUROCODE_MCP_URL", url)
    end)

    :ok
  end

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, value), do: System.put_env(key, value)

  test "OUROCODE_MCP_AUTOSTART=0 disables autostart without spawning" do
    System.put_env("OUROCODE_MCP_AUTOSTART", "0")

    assert {:ok, %{mode: :disabled}} = McpDaemon.maybe_start()
  end

  test "an already-listening port is adopted, never double-spawned" do
    System.delete_env("OUROCODE_MCP_AUTOSTART")
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(listen)
    System.put_env("OUROCODE_MCP_URL", "http://127.0.0.1:#{port}/mcp")

    assert {:ok, %{mode: :external} = handle} = McpDaemon.maybe_start()
    assert McpDaemon.describe(handle) =~ "using existing server"

    :gen_tcp.close(listen)
  end

  test "default path (no explicit URL) targets a fresh per-instance port, not 4000" do
    System.delete_env("OUROCODE_MCP_AUTOSTART")
    System.delete_env("OUROCODE_MCP_URL")

    assert {:spawn, "127.0.0.1", port_a, url_a, false} = McpDaemon.resolve_target()
    assert {:spawn, "127.0.0.1", port_b, _url_b, false} = McpDaemon.resolve_target()

    # Ephemeral and per-instance: not the legacy fixed default, and two
    # launches do not collide on the same port (multi-tab isolation).
    assert port_a != 4000
    assert port_a != port_b
    assert url_a == "http://127.0.0.1:#{port_a}/mcp"
  end

  test "an explicit but closed URL is spawned exactly there (never hijacked)" do
    System.delete_env("OUROCODE_MCP_AUTOSTART")
    System.put_env("OUROCODE_MCP_URL", "http://127.0.0.1:4999/mcp")

    assert {:spawn, "127.0.0.1", 4999, "http://127.0.0.1:4999/mcp", true} =
             McpDaemon.resolve_target()
  end

  test "auto launch exports its per-instance URL so the BEAM targets this server" do
    System.delete_env("OUROCODE_MCP_AUTOSTART")
    System.delete_env("OUROCODE_MCP_URL")

    spawn_fun = fn _host, _port, _llm_backend -> {:ok, :fake_port, 999_999} end

    assert {:ok, %{mode: :spawned, os_pid: 999_999, url: url}} =
             McpDaemon.maybe_start(spawn_fun: spawn_fun, wait?: false)

    # The rest of this process (LoopBindings/interview) now resolves to it.
    assert System.get_env("OUROCODE_MCP_URL") == url
    assert url =~ ~r{^http://127\.0\.0\.1:\d+/mcp$}
  end

  test "auto launch forwards the requested LLM backend to the spawned server" do
    System.delete_env("OUROCODE_MCP_AUTOSTART")
    System.delete_env("OUROCODE_MCP_URL")
    parent = self()

    spawn_fun = fn host, port, llm_backend ->
      send(parent, {:spawned_with, host, port, llm_backend})
      {:ok, :fake_port, 101_010}
    end

    assert {:ok, %{mode: :spawned, llm_backend: "codex"}} =
             McpDaemon.maybe_start(spawn_fun: spawn_fun, wait?: false, llm_backend: "codex")

    assert_receive {:spawned_with, "127.0.0.1", port, "codex"}
    assert is_integer(port)
  end

  test "spawned handle exposes its redirected log path when available" do
    System.delete_env("OUROCODE_MCP_AUTOSTART")
    System.delete_env("OUROCODE_MCP_URL")

    spawn_fun = fn _host, _port, _llm_backend ->
      {:ok, :fake_port, 101_011, "/tmp/ourocode-mcp-test.log"}
    end

    assert {:ok, %{mode: :spawned, log_path: "/tmp/ourocode-mcp-test.log"}} =
             McpDaemon.maybe_start(spawn_fun: spawn_fun, wait?: false)
  end

  test "an explicit operator URL is never overwritten by a spawn" do
    System.delete_env("OUROCODE_MCP_AUTOSTART")
    System.put_env("OUROCODE_MCP_URL", "http://127.0.0.1:4998/mcp")

    spawn_fun = fn _host, _port, _llm_backend -> {:ok, :fake_port, 4242} end

    assert {:ok, %{mode: :spawned, url: "http://127.0.0.1:4998/mcp"}} =
             McpDaemon.maybe_start(spawn_fun: spawn_fun, wait?: false)

    assert System.get_env("OUROCODE_MCP_URL") == "http://127.0.0.1:4998/mcp"
  end

  test "stop/1 is a safe no-op for non-spawned handles" do
    assert :ok == McpDaemon.stop(nil)
    assert :ok == McpDaemon.stop(%{mode: :external, url: "http://x/mcp"})
    assert :ok == McpDaemon.stop(%{mode: :disabled, url: "http://x/mcp"})
  end

  test "stop/1 reaps the per-instance OS process (no orphan on tab close)" do
    {command, args} = PortPrograms.long_running_command()

    erl_port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        :hide,
        args: args
      ])

    {:os_pid, os_pid} = Port.info(erl_port, :os_pid)
    assert_os_process_alive(os_pid)

    assert :ok ==
             McpDaemon.stop(%{mode: :spawned, port: erl_port, os_pid: os_pid, url: "u"})

    refute_os_process_alive(os_pid)
  end

  test "describe/1 renders every mode" do
    assert McpDaemon.describe(%{mode: :spawned, url: "u"}) =~ "spawned"
    assert McpDaemon.describe(%{mode: :external, url: "u"}) =~ "existing"
    assert McpDaemon.describe(%{mode: :disabled, url: "u"}) =~ "disabled"
    assert McpDaemon.describe(%{mode: :unavailable, url: "u"}) =~ "unavailable"
  end
end
