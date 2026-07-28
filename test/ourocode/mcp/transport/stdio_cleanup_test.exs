defmodule Ourocode.MCP.Transport.StdioCleanupTest do
  use ExUnit.Case, async: false

  alias Ourocode.MCP.Transport.Stdio

  setup do
    original_stale_cleanup_timeout_ms = Application.get_env(:ourocode, :stale_cleanup_timeout_ms)
    original_cleanup_policy = Application.get_env(:ourocode, :cleanup_policy)

    Application.delete_env(:ourocode, :cleanup_policy)
    Application.put_env(:ourocode, :stale_cleanup_timeout_ms, 5_000)

    on_exit(fn ->
      restore_env(:stale_cleanup_timeout_ms, original_stale_cleanup_timeout_ms)
      restore_env(:cleanup_policy, original_cleanup_policy)
    end)
  end

  test "default-config stdio cleanup closes opened port within configured timeout" do
    script = """
    while IFS= read -r line; do
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"child-cleanup-1","seq":1,"token":"cleanup"}}'
      printf '%s\n' '{"jsonrpc":"2.0","id":"1","result":{"ok":true,"childID":"child-cleanup-1","seq":2}}'
    done
    """

    {command, args} = Ourocode.Test.PortPrograms.shell_script(script)

    {:ok, transport} =
      Stdio.start_link(
        command: command,
        args: args,
        parent_call_id: "parent-cleanup-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-cleanup-1"},
        event_sink: self()
      )

    transport_ref = Process.monitor(transport)

    assert_receive {:ourocode_event,
                    %{type: :transport_started, parent_call_id: "parent-cleanup-1"}}

    assert {:ok, %{"ok" => true, "childID" => "child-cleanup-1", "seq" => 2}} =
             Stdio.call_parent(transport, "tools/call", %{"name" => "synthetic.cleanup"},
               timeout: 5_000
             )

    assert %{port: port, port_open?: true, cleanup_timeout_ms: 5_000} = Stdio.snapshot(transport)
    assert is_port(port)
    assert port_open?(port)

    assert_receive {:ourocode_event,
                    %{
                      type: :transport_cleanup,
                      parent_call_id: "parent-cleanup-1",
                      cleanup_reason: :idle_timeout,
                      stale_cleanup_timeout_ms: 5_000,
                      released_resources: %{ports: 1}
                    }},
                   6_000

    assert_receive {:DOWN, ^transport_ref, :process, ^transport, :normal}, 6_000
    refute port_open?(port)
  end

  defp port_open?(port) do
    !!Port.info(port)
  rescue
    ArgumentError -> false
  end

  defp restore_env(key, nil), do: Application.delete_env(:ourocode, key)
  defp restore_env(key, value), do: Application.put_env(:ourocode, key, value)
end
