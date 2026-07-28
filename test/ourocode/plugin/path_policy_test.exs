defmodule Ourocode.Plugin.PathPolicyTest do
  use ExUnit.Case, async: false

  alias Ourocode.Plugin.PathPolicy

  setup do
    original_allowed_roots = Application.get_env(:ourocode, :plugin_allowed_roots)

    on_exit(fn ->
      restore_env(:plugin_allowed_roots, original_allowed_roots)
    end)
  end

  test "accepts an absolute plugin path under a configured allowed root" do
    allowed_root = tmp_dir!("absolute-root")
    plugin_path = Path.join(allowed_root, "official-plugin")

    assert {:ok, expanded_path} =
             PathPolicy.validate(plugin_path, allowed_roots: [allowed_root])

    assert expanded_path == Path.expand(plugin_path)
  end

  test "accepts a relative plugin path under a configured relative allowed root" do
    base_dir = tmp_dir!("relative-base")
    allowed_root = "plugins"
    plugin_path = Path.join(["plugins", "community-plugin"])

    assert {:ok, expanded_path} =
             PathPolicy.validate(plugin_path,
               allowed_roots: [allowed_root],
               base_dir: base_dir
             )

    assert expanded_path == Path.expand(plugin_path, base_dir)
  end

  test "accepts paths under application-configured allowed roots" do
    allowed_root = tmp_dir!("configured-root")
    plugin_path = Path.join(allowed_root, "official-plugin")
    Application.put_env(:ourocode, :plugin_allowed_roots, [allowed_root])

    assert {:ok, expanded_path} = PathPolicy.validate(plugin_path)
    assert expanded_path == Path.expand(plugin_path)
  end

  test "rejects a plugin path outside every configured allowed root" do
    base_dir = tmp_dir!("outside-base")

    assert {:error, :plugin_path_not_allowed} =
             PathPolicy.validate("../outside-plugin",
               allowed_roots: ["plugins"],
               base_dir: base_dir
             )
  end

  test "rejects traversal attempts with ../ segments that escape an allowed root" do
    base_dir = tmp_dir!("dot-dot-base")
    File.mkdir_p!(Path.join(base_dir, "plugins"))

    assert {:error, :plugin_path_not_allowed} =
             PathPolicy.validate("plugins/../outside-plugin",
               allowed_roots: ["plugins"],
               base_dir: base_dir
             )
  end

  test "rejects normalized escape paths outside an allowed root" do
    base_dir = tmp_dir!("normalized-base")
    File.mkdir_p!(Path.join(base_dir, "plugins"))

    assert {:error, :plugin_path_not_allowed} =
             PathPolicy.validate("plugins/official/../../outside-plugin",
               allowed_roots: ["plugins/official"],
               base_dir: base_dir
             )
  end

  test "rejects link escape through an allowed root" do
    base_dir = tmp_dir!("symlink-base")
    allowed_root = Path.join(base_dir, "plugins")
    outside_root = tmp_dir!("symlink-outside")
    File.mkdir_p!(allowed_root)

    link_path = Path.join(allowed_root, "linked-outside")

    case create_directory_link(outside_root, link_path) do
      :ok ->
        try do
          assert {:error, :plugin_path_not_allowed} =
                   PathPolicy.validate(Path.join(link_path, "community-plugin"),
                     allowed_roots: [allowed_root]
                   )
        after
          remove_directory_link(link_path)
        end

      {:error, reason} ->
        flunk("failed to create link for path policy test: #{inspect(reason)}")
    end
  end

  defp tmp_dir!(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-plugin-path-policy-test-#{name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)

    on_exit(fn ->
      File.rm_rf!(path)
    end)

    path
  end

  defp restore_env(key, nil), do: Application.delete_env(:ourocode, key)
  defp restore_env(key, value), do: Application.put_env(:ourocode, key, value)

  defp create_directory_link(target_path, link_path) do
    case File.ln_s(target_path, link_path) do
      :ok -> :ok
      {:error, :eperm} -> create_windows_junction(target_path, link_path)
      {:error, reason} -> {:error, {:symlink, reason}}
    end
  end

  defp create_windows_junction(target_path, link_path) do
    if windows?() do
      case System.cmd(
             "cmd.exe",
             ["/d", "/c", "mklink", "/J", windows_path(link_path), windows_path(target_path)],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {:junction, status, String.trim(output)}}
      end
    else
      {:error, :eperm}
    end
  end

  defp remove_directory_link(link_path) do
    if windows?() do
      System.cmd("cmd.exe", ["/d", "/c", "rmdir", windows_path(link_path)],
        stderr_to_stdout: true
      )
    else
      File.rm(link_path)
    end
  end

  defp windows_path(path), do: path |> Path.expand() |> String.replace("/", "\\")
  defp windows?, do: match?({:win32, _}, :os.type())
end
