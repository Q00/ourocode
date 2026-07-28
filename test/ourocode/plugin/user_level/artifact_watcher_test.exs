defmodule Ourocode.Plugin.UserLevel.ArtifactWatcherTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.UserLevel.ArtifactWatcher
  alias Ourocode.Plugin.UserLevel.Capability.Command, as: CommandCapability

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "ourocode_artifact_watcher_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{cwd: tmp}
  end

  defp write!(path, content) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, content)
  end

  defp path_key(path) do
    path
    |> Path.expand()
    |> String.replace("\\", "/")
    |> maybe_downcase_windows_path()
  end

  defp maybe_downcase_windows_path(path) do
    case :os.type() do
      {:win32, _name} -> String.downcase(path)
      _other -> path
    end
  end

  test "matches a seed.md under the declared glob", %{cwd: cwd} do
    {:ok, command} =
      CommandCapability.new(%{
        name: "tdd",
        risk_class: "handoff_producing",
        expected_artifacts: [".omx/superpowers/runs/*/seed.md"]
      })

    seed = Path.join([cwd, ".omx", "superpowers", "runs", "abc123", "seed.md"])
    write!(seed, "# seed\n")

    [artifact] = ArtifactWatcher.scan(command, cwd)

    assert artifact.kind == :seed
    assert path_key(artifact.path) == path_key(seed)
    assert artifact.glob == ".omx/superpowers/runs/*/seed.md"
    assert artifact.size > 0
    assert "sha256:" <> _ = artifact.digest
    assert %DateTime{} = artifact.generated_at
  end

  test "classifies handoff and report files", %{cwd: cwd} do
    {:ok, command} =
      CommandCapability.new(%{
        name: "tdd",
        risk_class: "handoff_producing",
        expected_artifacts: [".omx/runs/*/*"]
      })

    handoff = Path.join([cwd, ".omx", "runs", "x", "handoff.md"])
    report = Path.join([cwd, ".omx", "runs", "x", "report.md"])
    log = Path.join([cwd, ".omx", "runs", "x", "audit.jsonl"])
    other = Path.join([cwd, ".omx", "runs", "x", "extra.bin"])

    Enum.each([handoff, report, log, other], &write!(&1, "data"))

    artifacts = ArtifactWatcher.scan(command, cwd)
    by_path = Map.new(artifacts, &{path_key(&1.path), &1.kind})

    assert by_path[path_key(handoff)] == :handoff
    assert by_path[path_key(report)] == :report
    assert by_path[path_key(log)] == :log
    assert by_path[path_key(other)] == :other
  end

  test "deduplicates artifacts that match multiple globs", %{cwd: cwd} do
    {:ok, command} =
      CommandCapability.new(%{
        name: "tdd",
        risk_class: "handoff_producing",
        expected_artifacts: [
          ".omx/runs/*/seed.md",
          ".omx/runs/**/*.md"
        ]
      })

    seed = Path.join([cwd, ".omx", "runs", "x", "seed.md"])
    write!(seed, "# seed\n")

    artifacts = ArtifactWatcher.scan(command, cwd)
    assert length(artifacts) == 1
  end

  test "returns empty list when nothing matches", %{cwd: cwd} do
    {:ok, command} =
      CommandCapability.new(%{
        name: "tdd",
        risk_class: "handoff_producing",
        expected_artifacts: [".omx/nothing/*.md"]
      })

    assert ArtifactWatcher.scan(command, cwd) == []
  end

  test "lstat?: false skips file metadata", %{cwd: cwd} do
    {:ok, command} =
      CommandCapability.new(%{
        name: "tdd",
        expected_artifacts: [".omx/x/*"]
      })

    write!(Path.join([cwd, ".omx", "x", "seed.md"]), "x")

    [artifact] = ArtifactWatcher.scan(command, cwd, lstat?: false)
    refute Map.has_key?(artifact, :size)
    refute Map.has_key?(artifact, :digest)
    refute Map.has_key?(artifact, :generated_at)
  end
end
