defmodule Ourocode.Config.RawLoaderTest do
  use ExUnit.Case, async: true

  alias Ourocode.Config.RawLoader

  test "discovers supported config files in deterministic order" do
    dir = unique_tmp_dir("discovery")
    File.mkdir_p!(Path.join(dir, ".ourocode"))
    File.write!(Path.join(dir, "ourocode.toml"), "runtime = true\n")
    File.write!(Path.join(dir, "ourocode.json"), ~s({"runtime":{"parallel-child-count":4}}))
    File.write!(Path.join(dir, ".ourocode/config.yaml"), "plugins:\n  enabled: true\n")
    File.write!(Path.join(dir, "ignored.txt"), "runtime = false\n")

    assert RawLoader.discover_config_files(dir) == [
             Path.join(dir, "ourocode.json"),
             Path.join(dir, "ourocode.toml"),
             Path.join(dir, ".ourocode/config.yaml")
           ]
  after
    File.rm_rf!(Process.get(:raw_loader_tmp_dir))
  end

  test "loads and deep-merges normalized JSON YAML and TOML config files" do
    dir = unique_tmp_dir("load")
    File.mkdir_p!(Path.join(dir, ".ourocode"))

    File.write!(
      Path.join(dir, "ourocode.json"),
      ~s({"runtime":{"parallel-child-count":4},"mcp":{"transports":["stdio"]}})
    )

    File.write!(
      Path.join(dir, "ourocode.yaml"),
      """
      runtime:
        repeat-count: 2
      wonder-tool:
        enabled: true
      """
    )

    File.write!(
      Path.join(dir, ".ourocode/config.toml"),
      """
      [runtime]
      parallel-child-count = 6
      """
    )

    assert {:ok, raw} = RawLoader.load(dir)
    assert raw.root_dir == dir

    assert Enum.map(raw.files, & &1.relative_path) == [
             "ourocode.json",
             "ourocode.yaml",
             ".ourocode/config.toml"
           ]

    assert raw.data == %{
             "runtime" => %{"parallel_child_count" => 6, "repeat_count" => 2},
             "mcp" => %{"transports" => ["stdio"]},
             "wonder_tool" => %{"enabled" => true}
           }
  after
    File.rm_rf!(Process.get(:raw_loader_tmp_dir))
  end

  test "preserves Windows path spelling while parsing CRLF config files with portable relative paths" do
    dir = unique_tmp_dir("windows-paths")
    File.mkdir_p!(Path.join(dir, ".ourocode"))
    config_path = Path.join(dir, ".ourocode/config.json")

    File.write!(
      config_path,
      "{\r\n  \"runtime\": {\r\n    \"repeat-count\": 3\r\n  }\r\n}\r\n"
    )

    assert {:ok, raw} = RawLoader.load(dir)
    assert raw.root_dir == dir

    assert [
             %{
               path: ^config_path,
               relative_path: ".ourocode/config.json",
               data: %{"runtime" => %{"repeat_count" => 3}}
             }
           ] = raw.files
  after
    File.rm_rf!(Process.get(:raw_loader_tmp_dir))
  end

  test "projects only supported runtime override keys from raw config" do
    raw = %{
      "runtime" => %{
        "parallel-child-count" => 4,
        "repeat_count" => 2,
        "unknown" => "ignored",
        "cleanup_policy" => %{
          "pane-state-retention-ms" => 900_000,
          "also_unknown" => "ignored"
        }
      }
    }

    assert RawLoader.runtime_overrides_from_raw(raw) ==
             {:ok,
              %{
                parallel_child_count: 4,
                repeat_count: 2,
                pane_state_retention_ms: 900_000
              }}
  end

  test "rejects malformed runtime sections" do
    assert RawLoader.runtime_overrides_from_raw(%{"runtime" => "fast"}) ==
             {:error, {:config_section_must_be_map, "runtime", "fast"}}
  end

  defp unique_tmp_dir(suffix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ourocode-raw-loader-#{suffix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    Process.put(:raw_loader_tmp_dir, dir)
    dir
  end
end
