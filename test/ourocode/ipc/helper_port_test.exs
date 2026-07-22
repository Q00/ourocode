defmodule Ourocode.IPC.HelperPortTest do
  use ExUnit.Case, async: true

  alias Ourocode.IPC.HelperPort

  test "opens helper port, writes the initial frame, and exposes response lines" do
    {command, args} = Ourocode.Test.PortPrograms.echo_line_command("echo:")

    assert {:ok, port} = HelperPort.open_and_write(command, args, "hello\n")
    assert_receive {^port, {:data, {:eol, "echo:hello"}}}, 1_000
    assert HelperPort.close(port) == :ok
  end

  test "returns a clean error when helper executable cannot be opened" do
    missing =
      Path.join(
        System.tmp_dir!(),
        "ourocode-missing-helper-#{System.unique_integer([:positive])}"
      )

    assert {:error, message} = HelperPort.open_and_write(missing, [], "hello\n")
    assert is_binary(message)
  end

  test "close is idempotent for already closed ports" do
    {command, args} = Ourocode.Test.PortPrograms.read_once_and_exit_command()

    assert {:ok, port} = HelperPort.open_and_write(command, args, "hello\n")
    assert HelperPort.close(port) == :ok
    assert HelperPort.close(port) == :ok
  end
end
