defmodule Ourocode.Runtime.ApplicationBootstrapTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.ApplicationBootstrap
  import Ourocode.Test.PathAssertions, only: [assert_same_path: 2]

  test "session_id preserves provided runtime session ids and generates terminal ids" do
    assert ApplicationBootstrap.session_id(%{runtime_session_id: "terminal-test"}) ==
             "terminal-test"

    assert ApplicationBootstrap.session_id(%{}) =~ ~r/^terminal-\d+$/
  end

  test "prepare expands project and journal paths and creates the journal directory" do
    project_dir = tmp_project_dir!("application-bootstrap")
    relative_journal = Path.join([project_dir, ".ourocode", "journals", "session.jsonl"])

    assert {:ok, prepared} =
             ApplicationBootstrap.prepare(
               %{runtime_session_id: "session", journal_path: relative_journal},
               project_dir
             )

    assert_same_path(prepared.project_dir, Path.expand(project_dir))
    assert_same_path(prepared.journal_path, Path.expand(relative_journal))
    assert File.dir?(Path.dirname(prepared.journal_path))

    File.rm_rf!(project_dir)
  end

  test "prepare rejects missing project directories" do
    missing_dir =
      Path.join(System.tmp_dir!(), "ourocode-missing-#{System.unique_integer([:positive])}")

    assert {:error,
            %{
              status: :unhealthy,
              healthy?: false,
              reason: {:missing_project_dir, actual_missing_dir}
            }} = ApplicationBootstrap.prepare(%{}, missing_dir)

    assert_same_path(actual_missing_dir, missing_dir)
  end

  test "default_journal_path uses the runtime session id" do
    assert ApplicationBootstrap.default_journal_path("/tmp/project", "terminal-1") ==
             Path.join(["/tmp/project", ".ourocode", "journals", "terminal-1.jsonl"])
  end

  defp tmp_project_dir!(name) do
    path = Path.join(System.tmp_dir!(), "ourocode-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
