defmodule Ourocode.Terminal.NodeTerminalRuntimeTest do
  use ExUnit.Case, async: false

  test "terminal rendering initializes from a Node terminal with browser globals absent" do
    node = System.find_executable("node")
    assert is_binary(node), "node executable is required for terminal runtime boundary test"

    script_path = Path.join(System.tmp_dir!(), "ourocode-node-terminal-#{unique_id()}.cjs")
    File.write!(script_path, node_terminal_script())
    Process.put(:node_terminal_script_path, script_path)

    {output, exit_status} =
      System.cmd(node, [script_path],
        env: [
          {"OUROCODE_ELIXIR_PA", code_paths()},
          {"OUROCODE_PROJECT_DIR", File.cwd!()}
        ],
        stderr_to_stdout: true
      )

    assert exit_status == 0, output
    assert output =~ "node_terminal_render_ok"
    assert output =~ "browser_globals_absent=true"
    assert output =~ "ui_surface=terminal"
    assert output =~ "frame_contains_prompt=true"
  after
    if script_path = Process.get(:node_terminal_script_path) do
      File.rm(script_path)
    end
  end

  defp node_terminal_script do
    """
    const { spawnSync } = require("node:child_process");
    const fs = require("node:fs");
    const os = require("node:os");
    const path = require("node:path");

    const forbiddenGlobals = ["window", "document", "HTMLElement", "DOMParser"];
    const presentGlobals = forbiddenGlobals.filter((name) => typeof globalThis[name] !== "undefined");

    if (presentGlobals.length > 0) {
      console.error(`browser globals present in Node terminal: ${presentGlobals.join(",")}`);
      process.exit(1);
    }

    const codePaths = (process.env.OUROCODE_ELIXIR_PA || "")
      .split(path.delimiter)
      .filter(Boolean)
      .flatMap((entry) => ["-pa", entry]);

    const elixirCode = `
    project_dir = System.fetch_env!("OUROCODE_PROJECT_DIR")
    journal_path = Path.join(System.tmp_dir!(), "ourocode-node-terminal-runtime.jsonl")
    File.rm(journal_path)

    result =
      try do
        {:ok, startup} =
          Ourocode.Terminal.Application.bootstrap(%{
            project_dir: project_dir,
            cwd: project_dir,
            config: Ourocode.Config.defaults(),
            runtime_session_id: "node-terminal-render-test",
            journal_path: journal_path
          })

        frame = Ourocode.Terminal.ShellRenderer.render_initial_frame(startup)
        Ourocode.Runtime.Application.stop(startup.runtime)

        [
          "node_terminal_render_ok",
          "browser_globals_absent=true",
          "ui_surface=\#{startup.ui_surface}",
          "root_ui_module=\#{inspect(startup.root_ui_module)}",
          "renderer=\#{inspect(startup.terminal_renderer)}",
          "frame_contains_prompt=\#{String.contains?(frame, "Prompt: Describe a task for a new session")}",
          "frame_contains_header=\#{String.contains?(frame, "ourocode agent")}"
        ]
      rescue
        exception ->
          ["node_terminal_render_failed", Exception.format(:error, exception, __STACKTRACE__)]
      after
        File.rm(journal_path)
      end

    IO.puts(Enum.join(result, "\\\\n"))
    if "node_terminal_render_ok" not in result, do: System.halt(1)
    `;

    const scriptDir = fs.mkdtempSync(path.join(os.tmpdir(), "ourocode-node-terminal-"));
    const elixirScriptPath = path.join(scriptDir, "runtime.exs");
    fs.writeFileSync(elixirScriptPath, elixirCode, "utf8");

    const elixirArgs = [...codePaths, elixirScriptPath];
    const child =
      process.platform === "win32"
        ? spawnSync(process.env.ComSpec || "cmd.exe", ["/d", "/s", "/c", "elixir.bat", ...elixirArgs], {
            cwd: process.env.OUROCODE_PROJECT_DIR,
            env: process.env,
            encoding: "utf8",
            stdio: ["ignore", "pipe", "pipe"],
          })
        : spawnSync("elixir", elixirArgs, {
            cwd: process.env.OUROCODE_PROJECT_DIR,
            env: process.env,
            encoding: "utf8",
            stdio: ["ignore", "pipe", "pipe"],
          });

    fs.rmSync(scriptDir, { recursive: true, force: true });

    process.stdout.write(child.stdout || "");
    process.stderr.write(child.stderr || "");
    if (child.error) process.stderr.write(child.error.message + "\\n");
    process.exit(child.status ?? 1);
    """
  end

  defp code_paths do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(&File.dir?/1)
    |> Enum.join(path_delimiter())
  end

  defp path_delimiter do
    case :os.type() do
      {:win32, _name} -> ";"
      _other -> ":"
    end
  end

  defp unique_id do
    System.unique_integer([:positive, :monotonic])
  end
end
