defmodule Ourocode.IPC.RPCTest do
  use ExUnit.Case, async: false

  alias Ourocode.IPC.RPC

  setup do
    original_rust_helpers = Application.get_env(:ourocode, :rust_helpers)

    on_exit(fn ->
      restore_env(:rust_helpers, original_rust_helpers)
    end)
  end

  test "invokes a helper over newline-delimited IPC and returns the correlated response result" do
    {command, args} =
      helper_command(
        """
        while IFS= read -r line; do
          if printf '%s' "$line" | grep -q '"message_id":"req-roundtrip-1"' &&
             printf '%s' "$line" | grep -q '"message_type":"ipc.rpc.request"' &&
             printf '%s' "$line" | grep -q '"method":"helper.scan"' &&
             printf '%s' "$line" | grep -q '"action":"run"'; then
            printf '%s\n' '{"version":1,"message_id":"res-roundtrip-1","message_type":"ipc.rpc.response","payload":{"request_id":"req-roundtrip-1","status":"ok","result":{"accepted":true,"transport":"stdio-jsonl","worker":"fake-rust-helper"}},"metadata":{"rust_worker":"fake-rust-helper"}}'
          else
            printf '%s\n' '{"version":1,"message_id":"res-roundtrip-1","message_type":"ipc.rpc.response","payload":{"request_id":"req-roundtrip-1","status":"error","error":{"code":"bad_request","message":"unexpected request frame"}}}'
          fi
        done
        """,
        """
        @echo off
        :loop
        set "line="
        set /p "line="
        if errorlevel 1 exit /b 0
        set "has_message_id="
        set "has_message_type="
        set "has_method="
        set "has_action="
        if not "%line:"message_id":"req-roundtrip-1"=%"=="%line%" set "has_message_id=1"
        if not "%line:"message_type":"ipc.rpc.request"=%"=="%line%" set "has_message_type=1"
        if not "%line:"method":"helper.scan"=%"=="%line%" set "has_method=1"
        if not "%line:"action":"run"=%"=="%line%" set "has_action=1"
        if defined has_message_id if defined has_message_type if defined has_method if defined has_action (
          echo {"version":1,"message_id":"res-roundtrip-1","message_type":"ipc.rpc.response","payload":{"request_id":"req-roundtrip-1","status":"ok","result":{"accepted":true,"transport":"stdio-jsonl","worker":"fake-rust-helper"}},"metadata":{"rust_worker":"fake-rust-helper"}}
        ) else (
          echo {"version":1,"message_id":"res-roundtrip-1","message_type":"ipc.rpc.response","payload":{"request_id":"req-roundtrip-1","status":"error","error":{"code":"bad_request","message":"unexpected request frame"}}}
        )
        goto loop
        """
      )

    {:ok, rpc} = RPC.start_link(command: command, args: args)

    assert {:ok,
            %{
              "accepted" => true,
              "transport" => "stdio-jsonl",
              "worker" => "fake-rust-helper"
            }} =
             RPC.invoke(
               rpc,
               "helper.scan",
               "run",
               %{"path" => "lib", "limit" => 10},
               request_id: "req-roundtrip-1",
               metadata: %{"rust_worker" => "fake-rust-helper"},
               timeout: 1_000
             )
  end

  test "returns a correlated timeout when a helper never replies" do
    {command, args} =
      helper_command(
        """
        while IFS= read -r _line; do
          :
        done
        """,
        """
        @echo off
        :loop
        set "line="
        set /p "line="
        if errorlevel 1 exit /b 0
        goto loop
        """
      )

    {:ok, rpc} = RPC.start_link(command: command, args: args)

    assert {:error, {:timeout, "req-stalled-1"}} =
             RPC.invoke(
               rpc,
               "helper.scan",
               "run",
               %{"path" => "lib"},
               request_id: "req-stalled-1",
               timeout: 50
             )

    assert Process.alive?(rpc)
  end

  test "returns structured Rust helper error replies without crashing the RPC process" do
    {command, args} =
      helper_command(
        """
        while IFS= read -r line; do
          if printf '%s' "$line" | grep -q '"message_id":"req-helper-error"'; then
            printf '%s\n' '{"version":1,"message_id":"res-helper-error","message_type":"ipc.rpc.response","payload":{"request_id":"req-helper-error","status":"error","error":{"code":"worker_failed","message":"helper failed","detail":{"exit_status":3,"stderr_tail":"bad input"}}},"metadata":{"rust_worker":"fake-rust-helper"}}'
          elif printf '%s' "$line" | grep -q '"message_id":"req-after-helper-error"'; then
            printf '%s\n' '{"version":1,"message_id":"res-after-helper-error","message_type":"ipc.rpc.response","payload":{"request_id":"req-after-helper-error","status":"ok","result":{"accepted":true}}}'
          fi
        done
        """,
        """
        @echo off
        :loop
        set "line="
        set /p "line="
        if errorlevel 1 exit /b 0
        if not "%line:req-helper-error=%"=="%line%" (
          echo {"version":1,"message_id":"res-helper-error","message_type":"ipc.rpc.response","payload":{"request_id":"req-helper-error","status":"error","error":{"code":"worker_failed","message":"helper failed","detail":{"exit_status":3,"stderr_tail":"bad input"}}},"metadata":{"rust_worker":"fake-rust-helper"}}
        ) else if not "%line:req-after-helper-error=%"=="%line%" (
          echo {"version":1,"message_id":"res-after-helper-error","message_type":"ipc.rpc.response","payload":{"request_id":"req-after-helper-error","status":"ok","result":{"accepted":true}}}
        )
        goto loop
        """
      )

    {:ok, rpc} = RPC.start_link(command: command, args: args)

    assert {:error,
            %{
              "code" => "worker_failed",
              "message" => "helper failed",
              "detail" => %{"exit_status" => 3, "stderr_tail" => "bad input"}
            }} =
             RPC.invoke(
               rpc,
               "helper.scan",
               "run",
               %{"path" => "missing"},
               request_id: "req-helper-error",
               timeout: 1_000
             )

    assert {:ok, %{"accepted" => true}} =
             RPC.invoke(
               rpc,
               "helper.scan",
               "run",
               %{"path" => "lib"},
               request_id: "req-after-helper-error",
               timeout: 1_000
             )
  end

  test "fails pending calls on malformed helper responses and remains reusable" do
    {command, args} =
      helper_command(
        """
        while IFS= read -r line; do
          if printf '%s' "$line" | grep -q '"message_id":"req-malformed-response"'; then
            printf '%s\n' '{malformed json'
          elif printf '%s' "$line" | grep -q '"message_id":"req-after-malformed"'; then
            printf '%s\n' '{"version":1,"message_id":"res-after-malformed","message_type":"ipc.rpc.response","payload":{"request_id":"req-after-malformed","status":"ok","result":{"accepted":true}}}'
          fi
        done
        """,
        """
        @echo off
        :loop
        set "line="
        set /p "line="
        if errorlevel 1 exit /b 0
        if not "%line:req-malformed-response=%"=="%line%" (
          echo {malformed json
        ) else if not "%line:req-after-malformed=%"=="%line%" (
          echo {"version":1,"message_id":"res-after-malformed","message_type":"ipc.rpc.response","payload":{"request_id":"req-after-malformed","status":"ok","result":{"accepted":true}}}
        )
        goto loop
        """
      )

    {:ok, rpc} = RPC.start_link(command: command, args: args)

    assert {:error, {:malformed_response, {:expected_object_key, "malformed json"}}} =
             RPC.invoke(
               rpc,
               "helper.scan",
               "run",
               %{"path" => "lib"},
               request_id: "req-malformed-response",
               timeout: 1_000
             )

    assert {:ok, %{"accepted" => true}} =
             RPC.invoke(
               rpc,
               "helper.scan",
               "run",
               %{"path" => "test"},
               request_id: "req-after-malformed",
               timeout: 1_000
             )
  end

  test "fails pending calls when the helper transport exits" do
    previous_flag = Process.flag(:trap_exit, true)

    try do
      {command, args} =
        helper_command(
          """
          IFS= read -r _line
          exit 7
          """,
          """
          @echo off
          set "line="
          set /p "line="
          exit /b 7
          """
        )

      {:ok, rpc} = RPC.start_link(command: command, args: args)

      assert {:error, {:port_exit, 7}} =
               RPC.invoke(
                 rpc,
                 "helper.scan",
                 "run",
                 %{"path" => "lib"},
                 request_id: "req-transport-exit",
                 timeout: 1_000
               )

      refute_receive {:EXIT, ^rpc, _reason}, 100
      assert Process.alive?(rpc)
    after
      Process.flag(:trap_exit, previous_flag)
    end
  end

  test "returns a clean error when the helper transport cannot start during invocation" do
    missing_command = Path.join(System.tmp_dir!(), "ourocode-helper-missing")

    {:ok, rpc} = RPC.start_link(command: missing_command)

    assert {:error, message} =
             RPC.invoke(
               rpc,
               "helper.scan",
               "run",
               %{"path" => "lib"},
               request_id: "req-missing-helper",
               timeout: 1_000
             )

    assert is_binary(message)
  end

  test "cleans timed-out pending calls and ignores late helper responses" do
    {command, args} =
      helper_command(
        """
        while IFS= read -r line; do
          if printf '%s' "$line" | grep -q '"message_id":"req-late-1"'; then
            sleep 0.2
            printf '%s\n' '{"version":1,"message_id":"res-late-1","message_type":"ipc.rpc.response","payload":{"request_id":"req-late-1","status":"ok","result":{"late":true}}}'
          elif printf '%s' "$line" | grep -q '"message_id":"req-after-timeout"'; then
            printf '%s\n' '{"version":1,"message_id":"res-after-timeout","message_type":"ipc.rpc.response","payload":{"request_id":"req-after-timeout","status":"ok","result":{"accepted":true}}}'
          fi
        done
        """,
        """
        @echo off
        set "line="
        set /p "line="
        if errorlevel 1 exit /b 0
        if not "%line:req-late-1=%"=="%line%" (
          ping -n 2 127.0.0.1 >nul
          echo {"version":1,"message_id":"res-late-1","message_type":"ipc.rpc.response","payload":{"request_id":"req-late-1","status":"ok","result":{"late":true}}}
        ) else if not "%line:req-after-timeout=%"=="%line%" (
          echo {"version":1,"message_id":"res-after-timeout","message_type":"ipc.rpc.response","payload":{"request_id":"req-after-timeout","status":"ok","result":{"accepted":true}}}
        )
        """
      )

    {:ok, rpc} = RPC.start_link(command: command, args: args)

    assert {:error, {:timeout, "req-late-1"}} =
             RPC.invoke(
               rpc,
               "helper.scan",
               "run",
               %{"path" => "lib"},
               request_id: "req-late-1",
               timeout: 50
             )

    assert {:ok, %{"accepted" => true}} =
             RPC.invoke(
               rpc,
               "helper.scan",
               "run",
               %{"path" => "test"},
               request_id: "req-after-timeout",
               timeout: 1_000
             )
  end

  test "rejects invalid helper RPC timeout values before opening a pending call" do
    {command, args} =
      helper_command(
        "while IFS= read -r _line; do :; done",
        """
        @echo off
        :loop
        set "line="
        set /p "line="
        if errorlevel 1 exit /b 0
        goto loop
        """
      )

    {:ok, rpc} = RPC.start_link(command: command, args: args)

    assert {:error, {:invalid_timeout, 0}} =
             RPC.invoke(
               rpc,
               "helper.scan",
               "run",
               %{"path" => "lib"},
               request_id: "req-invalid-timeout",
               timeout: 0
             )
  end

  test "re-resolves configured Rust helper path and version for each invocation" do
    command = helper_shell!()

    helper_v1 =
      helper_args(
        """
        IFS= read -r _line
        printf '%s\n' '{"version":1,"message_id":"res-helper-version-1","message_type":"ipc.rpc.response","payload":{"request_id":"req-helper-version-1","status":"ok","result":{"helper_version":"v1"}}}'
        """,
        """
        @echo off
        set "line="
        set /p "line="
        echo {"version":1,"message_id":"res-helper-version-1","message_type":"ipc.rpc.response","payload":{"request_id":"req-helper-version-1","status":"ok","result":{"helper_version":"v1"}}}
        """
      )

    helper_v2 =
      helper_args(
        """
        IFS= read -r _line
        printf '%s\n' '{"version":1,"message_id":"res-helper-version-2","message_type":"ipc.rpc.response","payload":{"request_id":"req-helper-version-2","status":"ok","result":{"helper_version":"v2"}}}'
        """,
        """
        @echo off
        set "line="
        set /p "line="
        echo {"version":1,"message_id":"res-helper-version-2","message_type":"ipc.rpc.response","payload":{"request_id":"req-helper-version-2","status":"ok","result":{"helper_version":"v2"}}}
        """
      )

    Application.put_env(:ourocode, :rust_helpers, %{
      scanner: %{path: command, args: helper_v1, version: "v1"}
    })

    {:ok, rpc} = RPC.start_link(helper: :scanner)

    assert {:ok, %{"helper_version" => "v1"}} =
             RPC.invoke(
               rpc,
               "helper.scan",
               "run",
               %{"path" => "lib"},
               request_id: "req-helper-version-1",
               timeout: 1_000
             )

    Application.put_env(:ourocode, :rust_helpers, %{
      scanner: %{path: command, args: helper_v2, version: "v2"}
    })

    assert {:ok, %{"helper_version" => "v2"}} =
             RPC.invoke(
               rpc,
               "helper.scan",
               "run",
               %{"path" => "lib"},
               request_id: "req-helper-version-2",
               timeout: 1_000
             )
  end

  test "uses an in-place updated helper executable on the next invocation without RPC restart" do
    helper_path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-helper-replacement-#{System.unique_integer([:positive])}#{helper_script_extension()}"
      )

    on_exit(fn -> File.rm(helper_path) end)

    write_helper_executable!(helper_path, "req-helper-replacement-1", "v1")

    {command, args} = helper_file_command(helper_path)
    {:ok, rpc} = RPC.start_link(command: command, args: args)
    rpc_pid = rpc

    assert {:ok, %{"binary_generation" => "v1", "request_id" => "req-helper-replacement-1"}} =
             RPC.invoke(
               rpc,
               "helper.scan",
               "run",
               %{"path" => "lib"},
               request_id: "req-helper-replacement-1",
               timeout: 1_000
             )

    write_helper_executable!(helper_path, "req-helper-replacement-2", "v2")

    assert Process.alive?(rpc_pid)

    assert {:ok, %{"binary_generation" => "v2", "request_id" => "req-helper-replacement-2"}} =
             RPC.invoke(
               rpc,
               "helper.scan",
               "run",
               %{"path" => "lib"},
               request_id: "req-helper-replacement-2",
               timeout: 1_000
             )

    assert Process.alive?(rpc_pid)
  end

  test "supervised restart discards old helper process state and uses latest configured helper" do
    command = helper_shell!()

    marker =
      Path.join(System.tmp_dir!(), "ourocode-rpc-restart-#{System.unique_integer([:positive])}")

    worker_name = :"ourocode_rpc_restart_#{System.unique_integer([:positive])}"

    helper_v1 =
      helper_args(
        """
        IFS= read -r _line
        touch "$1"
        sleep 5
        printf '%s\n' '{"version":1,"message_id":"res-before-restart","message_type":"ipc.rpc.response","payload":{"request_id":"req-before-restart","status":"ok","result":{"helper_version":"v1","stale":true}}}'
        """,
        """
        @echo off
        set "line="
        set /p "line="
        type nul > "%~2"
        ping -n 6 127.0.0.1 >nul
        echo {"version":1,"message_id":"res-before-restart","message_type":"ipc.rpc.response","payload":{"request_id":"req-before-restart","status":"ok","result":{"helper_version":"v1","stale":true}}}
        """,
        ["helper-v1", marker]
      )

    helper_v2 =
      helper_args(
        """
        IFS= read -r _line
        printf '%s\n' '{"version":1,"message_id":"res-after-restart","message_type":"ipc.rpc.response","payload":{"request_id":"req-after-restart","status":"ok","result":{"helper_version":"v2","fresh_worker":true}}}'
        """,
        """
        @echo off
        set "line="
        set /p "line="
        echo {"version":1,"message_id":"res-after-restart","message_type":"ipc.rpc.response","payload":{"request_id":"req-after-restart","status":"ok","result":{"helper_version":"v2","fresh_worker":true}}}
        """,
        ["helper-v2"]
      )

    Application.put_env(:ourocode, :rust_helpers, %{
      scanner: %{path: command, args: helper_v1, version: "v1"}
    })

    {:ok, supervisor} =
      Supervisor.start_link(
        [
          {RPC,
           [
             id: :scanner_rpc,
             helper: :scanner,
             name: worker_name,
             restart: :permanent,
             shutdown: 500
           ]}
        ],
        strategy: :one_for_one
      )

    on_exit(fn ->
      File.rm(marker)

      if Process.alive?(supervisor) do
        Supervisor.stop(supervisor)
      end
    end)

    original_pid = Process.whereis(worker_name)
    assert is_pid(original_pid)

    blocked_call =
      Task.async(fn ->
        try do
          RPC.invoke(
            worker_name,
            "helper.scan",
            "run",
            %{"path" => "lib"},
            request_id: "req-before-restart",
            timeout: 5_000
          )
        catch
          :exit, reason -> {:caller_exit, reason}
        end
      end)

    assert eventually?(fn -> File.exists?(marker) end)

    original_state = :sys.get_state(original_pid)
    assert Map.has_key?(original_state.pending, "req-before-restart")
    refute original_state.ports == %{}

    Process.exit(original_pid, :shutdown)
    assert {:caller_exit, _reason} = Task.await(blocked_call, 1_000)

    assert eventually?(fn ->
             restarted_pid = Process.whereis(worker_name)
             is_pid(restarted_pid) and restarted_pid != original_pid
           end)

    restarted_pid = Process.whereis(worker_name)
    restarted_state = :sys.get_state(restarted_pid)
    assert restarted_state.pending == %{}
    assert restarted_state.ports == %{}
    assert restarted_state.request_seq == 0

    Application.put_env(:ourocode, :rust_helpers, %{
      scanner: %{path: command, args: helper_v2, version: "v2"}
    })

    assert {:ok, %{"fresh_worker" => true, "helper_version" => "v2"}} =
             RPC.invoke(
               worker_name,
               "helper.scan",
               "run",
               %{"path" => "lib"},
               request_id: "req-after-restart",
               timeout: 1_000
             )
  end

  defp restore_env(key, nil), do: Application.delete_env(:ourocode, key)
  defp restore_env(key, value), do: Application.put_env(:ourocode, key, value)

  defp helper_command(unix_script, windows_script) do
    {helper_shell!(), helper_args(unix_script, windows_script)}
  end

  defp helper_shell! do
    command =
      if windows?() do
        System.find_executable("cmd")
      else
        System.find_executable("sh")
      end

    command || flunk("no portable helper shell found for IPC RPC tests")
  end

  defp helper_args(unix_script, windows_script, extra_args \\ []) do
    if windows?() do
      path =
        Path.join(
          System.tmp_dir!(),
          "ourocode-rpc-helper-#{System.unique_integer([:positive])}.cmd"
        )

      File.write!(path, windows_script)
      on_exit(fn -> File.rm(path) end)

      [
        "/d",
        "/q",
        "/c",
        path
        | extra_args
      ]
    else
      ["-c", unix_script | extra_args]
    end
  end

  defp helper_file_command(path) do
    if windows?() do
      {helper_shell!(), ["/d", "/q", "/c", path]}
    else
      {path, []}
    end
  end

  defp helper_script_extension do
    if windows?(), do: ".cmd", else: ".sh"
  end

  defp write_helper_executable!(path, request_id, generation) do
    File.write!(path, helper_executable(request_id, generation))

    unless windows?() do
      File.chmod!(path, 0o755)
    end
  end

  defp helper_executable(request_id, generation) do
    response =
      [
        "{\"version\":1,",
        "\"message_id\":\"res-#{request_id}\",",
        "\"message_type\":\"ipc.rpc.response\",",
        "\"payload\":{",
        "\"request_id\":\"#{request_id}\",",
        "\"status\":\"ok\",",
        "\"result\":{\"binary_generation\":\"#{generation}\",\"request_id\":\"#{request_id}\"}",
        "}}"
      ]
      |> IO.iodata_to_binary()

    if windows?() do
      Enum.join(
        [
          "@echo off",
          "set \"line=\"",
          "set /p \"line=\"",
          "echo #{response}"
        ],
        "\r\n"
      )
    else
      Enum.join(
        [
          "#!/bin/sh",
          "IFS= read -r _line",
          "printf '%s\\n' '#{response}'"
        ],
        "\n"
      )
    end
  end

  defp windows?, do: match?({:win32, _}, :os.type())

  defp eventually?(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    eventually_until?(fun, deadline)
  end

  defp eventually_until?(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        eventually_until?(fun, deadline)
    end
  end
end
