defmodule Ourocode.Model.CliTest do
  use ExUnit.Case, async: true

  alias Ourocode.Model.Cli

  test "known CLI specs exclude slow agent CLIs" do
    assert Cli.specs() == %{gemini: "gemini"}
  end

  test "gemini args ignore the system prompt" do
    refute "--append-system-prompt" in Cli.args(:gemini, "hi", "You are ourocode.")
  end

  test "Windows runner invokes the CLI executable directly without POSIX shell dependency" do
    path = "C:/Program Files/Gemini/gemini.exe"
    args = ["-p", "hello from a path with spaces"]

    assert Cli.runner_command(path, args, {:win32, :nt}, fn _bin ->
             flunk("unexpected shell lookup")
           end) ==
             {path, args}
  end

  test "Unix runner keeps the stdin-closing shell wrapper" do
    path = "/opt/gemini cli/bin/gemini"
    args = ["-p", "hello from a path with spaces"]

    assert Cli.runner_command(path, args, {:unix, :linux}, fn "sh" -> "/usr/bin/sh" end) ==
             {"/usr/bin/sh", ["-c", ~s(exec "$0" "$@" </dev/null), path | args]}
  end

  test "retries a run that fails before emitting any output" do
    gemini_path = fake_executable_path()
    calls = :counters.new(1, [])

    run = fn :gemini, ^gemini_path, ["-p", "hello"], on_chunk ->
      :counters.add(calls, 1, 1)

      case :counters.get(calls, 1) do
        1 ->
          {:error, {:exit, 1}}

        2 ->
          on_chunk.("hello")
          {:ok, "hello"}
      end
    end

    assert {:ok, "hello"} =
             Cli.stream(
               :gemini,
               "hello",
               [which: fn "gemini" -> gemini_path end, retry_base_delay_ms: 1, run: run],
               fn _chunk -> :ok end
             )

    assert :counters.get(calls, 1) == 2
  end

  test "does not retry once output has reached the renderer" do
    gemini_path = fake_executable_path()
    calls = :counters.new(1, [])
    parent = self()

    run = fn :gemini, ^gemini_path, ["-p", "hello"], on_chunk ->
      :counters.add(calls, 1, 1)
      on_chunk.("partial ")
      {:error, {:exit, 1}}
    end

    assert {:error, {:exit, 1}} =
             Cli.stream(
               :gemini,
               "hello",
               [which: fn "gemini" -> gemini_path end, retry_base_delay_ms: 1, run: run],
               fn chunk -> send(parent, {:chunk, chunk}) end
             )

    assert :counters.get(calls, 1) == 1
    assert_received {:chunk, "partial "}
  end

  test "a persistent silent failure surfaces after the retry budget" do
    gemini_path = fake_executable_path()
    calls = :counters.new(1, [])

    run = fn :gemini, ^gemini_path, ["-p", "hello"], _on_chunk ->
      :counters.add(calls, 1, 1)
      {:error, {:exit, 7}}
    end

    assert {:error, {:exit, 7}} =
             Cli.stream(
               :gemini,
               "hello",
               [which: fn "gemini" -> gemini_path end, retry_base_delay_ms: 1, run: run],
               fn _chunk -> :ok end
             )

    assert :counters.get(calls, 1) == 3
  end

  defp fake_executable_path do
    Path.join(System.tmp_dir!(), "gemini-test-bin-#{System.unique_integer([:positive])}")
  end
end
