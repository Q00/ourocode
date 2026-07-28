defmodule Ourocode.Terminal.TtyDriverTest do
  use ExUnit.Case, async: false

  alias Ourocode.Terminal.TtyDriver

  test "helper_path picks the first existing path" do
    dir = System.tmp_dir!()
    missing = Path.join(dir, "ourocode-tty-missing-#{System.unique_integer([:positive])}")
    existing = Path.join(dir, "ourocode-tty-existing-#{System.unique_integer([:positive])}")

    File.write!(existing, "")
    on_exit(fn -> File.rm(existing) end)

    assert TtyDriver.helper_path([nil, missing, existing]) == existing
  end

  test "helper_path resolves packaged Windows exe before other bundled helpers" do
    # Given
    root = temp_root!()
    packaged_exe = touch!(root, "bin/ourocode_tty.exe")
    touch!(root, "bin/ourocode_tty")
    touch!(root, "rust/ourocode_ipc/target/release/ourocode_tty.exe")

    # When
    actual = in_project_root(root, fn -> TtyDriver.helper_path() end)

    # Then
    assert_same_path(actual, packaged_exe)
  end

  test "helper_path falls back to source Windows exe before source Unix helper" do
    # Given
    root = temp_root!()
    source_exe = touch!(root, "rust/ourocode_ipc/target/release/ourocode_tty.exe")
    touch!(root, "rust/ourocode_ipc/target/release/ourocode_tty")

    # When
    actual = in_project_root(root, fn -> TtyDriver.helper_path() end)

    # Then
    assert_same_path(actual, source_exe)
  end

  test "helper_path returns nil when no helper candidate exists" do
    # Given
    root = temp_root!()

    # When
    actual = in_project_root(root, fn -> TtyDriver.helper_path() end)

    # Then
    assert actual == nil
  end

  test "terminal control sequences enable and disable SGR mouse reporting" do
    assert TtyDriver.enter_sequence() =~ "?1003h"
    assert TtyDriver.enter_sequence() =~ "?1006h"
    assert TtyDriver.exit_sequence() =~ "?1003l"
    assert TtyDriver.exit_sequence() =~ "?1006l"
  end

  test "parse_header accepts complete helper header and preserves key bytes" do
    assert TtyDriver.parse_header("120 40\nabc") == {:ok, 120, 40, "abc"}
    assert TtyDriver.parse_header("120") == :partial
    assert TtyDriver.parse_header("0 40\n") == :error
    assert TtyDriver.parse_header("bad header\n") == :error
  end

  test "port_options use Port stdio protocol on Windows and fd 3/4 protocol on Unix" do
    windows_options = TtyDriver.port_options({:win32, :nt})
    unix_options = TtyDriver.port_options({:unix, :linux})

    assert windows_options == [:binary, :exit_status]
    refute :hide in windows_options
    refute :nouse_stdio in windows_options

    assert unix_options == [:binary, :exit_status, :nouse_stdio, :hide]
  end

  test "next_chunk surfaces file-cache notifications and poll ticks" do
    send(self(), {:file_cache_ready, ["lib/a.ex"]})
    assert TtyDriver.next_chunk(nil, 0) == {:file_cache_ready, ["lib/a.ex"]}
    assert TtyDriver.next_chunk(nil, 0) == :tick
  end

  test "next_chunk decodes complete helper resize and redraw control frames" do
    send(self(), {nil, {:data, "\e]777;ourocode-resize=132x43\a"}})
    assert TtyDriver.next_chunk(nil, 0) == {:resize, {132, 43}}

    send(self(), {nil, {:data, "\e]777;ourocode-control=redraw\a"}})
    assert TtyDriver.next_chunk(nil, 0) == {:control, :redraw}
  end

  test "next_chunk ignores malformed helper control frames instead of surfacing raw bytes" do
    send(self(), {nil, {:data, "\e]777;ourocode-resize=wide-short\a"}})
    assert TtyDriver.next_chunk(nil, 0) == :tick
  end

  test "next_chunk preserves terminal paste bytes that merely contain helper-like text" do
    paste = "\e[200~\e]777;ourocode-resize=132x43\a\e[201~"

    send(self(), {nil, {:data, paste}})
    assert TtyDriver.next_chunk(nil, 0) == {:ok, paste}
  end

  test "next_chunk separates raw bytes before a coalesced helper frame" do
    frame = "\e]777;ourocode-resize=132x43\a"

    send(self(), {nil, {:data, "a" <> frame}})
    assert TtyDriver.next_chunk(nil, 0) == {:ok, "a", frame}
  end

  defp temp_root! do
    root = Path.join(System.tmp_dir!(), "ourocode-tty-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp touch!(root, relative_path) do
    path = Path.join(root, relative_path)
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, "")
    path
  end

  defp in_project_root(root, fun) do
    original_cwd = File.cwd!()
    original_env = System.get_env("OUROCODE_TTY")

    try do
      System.delete_env("OUROCODE_TTY")
      File.cd!(root)
      fun.()
    after
      File.cd!(original_cwd)
      restore_env(original_env)
    end
  end

  defp restore_env(nil), do: System.delete_env("OUROCODE_TTY")
  defp restore_env(value), do: System.put_env("OUROCODE_TTY", value)

  defp assert_same_path(left, right) do
    if match?({:win32, _}, :os.type()) do
      assert windows_path_key(left) == windows_path_key(right)
    else
      assert left == right
    end
  end

  defp windows_path_key(path) do
    path
    |> String.replace("\\", "/")
    |> String.downcase()
  end
end
