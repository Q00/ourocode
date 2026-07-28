defmodule Ourocode.Runtime.InterviewRouter.ToolSandboxTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.InterviewRouter.ToolSandbox

  test "read returns file contents inside the project root" do
    root = sandbox_dir!()
    File.write!(Path.join(root, "mix.exs"), "defmodule Demo.MixProject do\nend\n")

    assert {"READ mix.exs", body} = ToolSandbox.run(:read, "mix.exs", root)
    assert body =~ "Demo.MixProject"
  end

  test "read keeps head and tail of an oversized file with an elision marker" do
    root = sandbox_dir!()
    content = "HEAD_MARK\n" <> String.duplicate("x", 60_000) <> "\nTAIL_MARK"
    File.write!(Path.join(root, "big.txt"), content)

    assert {"READ big.txt", body} = ToolSandbox.run(:read, "big.txt", root)
    assert body =~ "HEAD_MARK"
    assert body =~ "TAIL_MARK"
    assert body =~ "bytes elided"
    assert byte_size(body) < byte_size(content)
  end

  test "read truncation never splits a multibyte character" do
    root = sandbox_dir!()
    # "a" prefix shifts the 3-byte Hangul run so both the head cut and the
    # tail cut land mid-character unless the cap is boundary-aware.
    File.write!(Path.join(root, "wide.txt"), "a" <> String.duplicate("가", 20_000))

    assert {"READ wide.txt", body} = ToolSandbox.run(:read, "wide.txt", root)
    assert String.valid?(body)
    assert body =~ "bytes elided"
  end

  test "read rejects unsafe path literals" do
    root = sandbox_dir!()

    assert {"READ ../secret", "rejected: parent escape"} =
             ToolSandbox.run(:read, "../secret", root)

    assert {"READ /etc/passwd", "rejected: absolute path"} =
             ToolSandbox.run(:read, "/etc/passwd", root)

    assert {"READ $HOME/.ssh/id_rsa", "rejected: shell expansion"} =
             ToolSandbox.run(:read, "$HOME/.ssh/id_rsa", root)
  end

  test "read rejects symlink escapes below the project root" do
    root = sandbox_dir!()
    link_escape!(root, "escape")

    assert {"READ escape/passwd", "rejected: symlinked path not allowed in sandbox"} =
             ToolSandbox.run(:read, "escape/passwd", root)
  end

  test "glob lists relative matches and rejects unsafe globs" do
    root = sandbox_dir!()
    File.mkdir_p!(Path.join(root, "lib/demo"))
    File.write!(Path.join(root, "lib/demo/a.ex"), "defmodule A, do: nil")
    File.write!(Path.join(root, "lib/demo/b.ex"), "defmodule B, do: nil")

    assert {"GLOB lib/**/*.ex", body} = ToolSandbox.run(:glob, "lib/**/*.ex", root)
    assert body =~ "lib/demo/a.ex"
    assert body =~ "lib/demo/b.ex"

    assert {"GLOB ../*.ex", "rejected: parent escape"} =
             ToolSandbox.run(:glob, "../*.ex", root)
  end

  test "grep is project-bounded and supports include globs" do
    root = sandbox_dir!()
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/demo.ex"), "defmodule Demo, do: :ok")
    File.write!(Path.join(root, "README.md"), "defmodule should not count")

    assert {"GREP defmodule *.ex", body} = ToolSandbox.run(:grep, "defmodule *.ex", root)
    assert body =~ "lib/demo.ex"
    refute body =~ "README.md"

    assert {"GREP defmodule ../*.ex", "rejected: unsafe glob"} =
             ToolSandbox.run(:grep, "defmodule ../*.ex", root)
  end

  test "unknown tools are rejected without execution" do
    assert {"UNKNOWN \"arg\"", "rejected: unknown tool"} =
             ToolSandbox.run(:shell, "arg", sandbox_dir!())
  end

  defp sandbox_dir! do
    root =
      Path.join(
        System.tmp_dir!(),
        "ourocode-router-sandbox-#{System.unique_integer([:positive])}"
      )

    remove_sandbox_root(root)
    File.mkdir_p!(root)
    on_exit(fn -> remove_sandbox_root(root) end)
    root
  end

  defp link_escape!(root, name) do
    link_path = Path.join(root, name)
    remove_escape_link(link_path)

    if match?({:win32, _}, :os.type()) do
      target =
        Path.join(
          System.tmp_dir!(),
          "ourocode-router-sandbox-target-#{System.unique_integer([:positive])}"
        )

      File.rm_rf!(target)
      File.mkdir_p!(target)
      on_exit(fn -> File.rm_rf(target) end)
      on_exit(fn -> remove_escape_link(link_path) end)

      {out, status} =
        System.cmd(
          "cmd",
          ["/d", "/c", "mklink", "/J", windows_path(link_path), windows_path(target)],
          stderr_to_stdout: true
        )

      assert status == 0, out
    else
      File.ln_s!("/etc", link_path)
      on_exit(fn -> remove_escape_link(link_path) end)
    end
  end

  defp remove_sandbox_root(root) do
    remove_escape_link(Path.join(root, "escape"))
    File.rm_rf(root)
  end

  defp remove_escape_link(path) do
    if match?({:win32, _}, :os.type()) do
      System.cmd("cmd", ["/d", "/c", "rmdir", windows_path(path)], stderr_to_stdout: true)
    else
      File.rm(path)
    end
  end

  defp windows_path(path), do: path |> Path.expand() |> String.replace("/", "\\")
end
