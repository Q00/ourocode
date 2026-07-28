defmodule Ourocode.Terminal.ResumeSessionsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal
  alias Ourocode.Terminal.ResumeSessions
  import Ourocode.Test.PathAssertions, only: [assert_same_path: 2]

  test "handles journal replay actions only" do
    assert ResumeSessions.handles?(:resume_session)
    assert ResumeSessions.handles?(:replay_journal)
    refute ResumeSessions.handles?(:show_status)
    refute ResumeSessions.handles?(:unknown)
  end

  test "lists journaled sessions beside the active journal path" do
    dir = tmp_dir!("resume-sessions")
    active_path = Path.join(dir, "active.jsonl")
    session_path = Path.join(dir, "session-alpha.jsonl")

    Journal.append!(session_path, %{type: :event, event_seq: 1})
    Journal.append!(session_path, %{type: :event, event_seq: 2})

    assert [
             %{id: "session-alpha", path: actual_path, event_count: 2, updated_label: updated}
           ] = ResumeSessions.list(%{journal_path: active_path})

    assert_same_path(actual_path, session_path)
    assert is_binary(updated)
  end

  test "resolves by session id or explicit journal file path" do
    dir = tmp_dir!("resume-session-resolve")
    active_path = Path.join(dir, "active.jsonl")
    session_path = Path.join(dir, "session-bravo.jsonl")

    File.write!(session_path, "")

    state = %{journal_path: active_path}

    assert {:ok, actual_session_path} = ResumeSessions.resolve_path(state, "session-bravo")
    assert_same_path(actual_session_path, session_path)

    assert {:ok, indexed_session_path} = ResumeSessions.resolve_path(state, "1")
    assert_same_path(indexed_session_path, session_path)

    external_path = Path.join(dir, "external.jsonl")
    File.write!(external_path, "")

    assert {:ok, actual_external_path} = ResumeSessions.resolve_path(state, external_path)
    assert_same_path(actual_external_path, external_path)

    assert ResumeSessions.resolve_path(state, "missing") ==
             {:error, {:unknown_resume_session, "missing"}}
  end

  test "runs resume command by listing sessions or replaying a selected session" do
    dir = tmp_dir!("resume-session-run")
    active_path = Path.join(dir, "active.jsonl")
    session_path = Path.join(dir, "session-charlie.jsonl")

    Journal.append!(session_path, %{type: :event, event_seq: 1})

    {:ok, output} = StringIO.open("")
    state = %{journal_path: active_path}

    assert {:ok, %{sessions: [%{id: "session-charlie", event_count: 1}]}} =
             ResumeSessions.run([], state, output)

    assert {:ok, %{path: actual_path, events: [_event]}} =
             ResumeSessions.run(["session-charlie"], state, output)

    assert_same_path(actual_path, session_path)

    {_input, text} = StringIO.contents(output)
    assert text =~ "resume workspace"
    assert text =~ "latest Saved session"
    assert text =~ "record 1"
    assert text =~ "task Saved session"
    assert text =~ "state 1 replay event"
    assert text =~ "action /resume 1"
    assert text =~ "actions /resume latest, /resume <number>, /resume --all"
    assert text =~ "resumed session-charlie: 1 events replayed"
  end

  test "renders empty and populated session lists" do
    {:ok, output} = StringIO.open("")

    assert :ok = ResumeSessions.render_sessions(output, [])

    assert :ok =
             ResumeSessions.render_sessions(output, [
               %{id: "session-echo", event_count: 3, path: "/tmp/session-echo.jsonl"}
             ])

    {_input, text} = StringIO.contents(output)
    assert text =~ "resume: no journaled sessions found"
    assert text =~ "resume workspace"
    assert text =~ "latest Saved session"
    assert text =~ "record 1"
    assert text =~ "state 3 replay events"
    refute text =~ "path=/tmp/session-echo.jsonl"
  end

  test "dispatch uses command args and state output" do
    dir = tmp_dir!("resume-session-dispatch")
    active_path = Path.join(dir, "active.jsonl")
    session_path = Path.join(dir, "session-delta.jsonl")

    Journal.append!(session_path, %{type: :event, event_seq: 1})

    {:ok, output} = StringIO.open("")
    state = %{journal_path: active_path, output: output}

    assert {:ok, %{sessions: [%{id: "session-delta"}]}} =
             ResumeSessions.dispatch(:resume_session, %{args: []}, state)

    assert {:ok, %{path: actual_path, events: [_event]}} =
             ResumeSessions.dispatch(:replay_journal, %{args: ["session-delta"]}, state)

    assert_same_path(actual_path, session_path)

    {_input, text} = StringIO.contents(output)
    assert text =~ "resume workspace"
    assert text =~ "resumed session-delta: 1 events replayed"
  end

  test "derives journal dir from startup runtime journal path or default cwd" do
    dir = tmp_dir!("resume-session-startup")
    journal_path = Path.join(dir, "runtime.jsonl")

    assert_same_path(
      ResumeSessions.journal_dir(%{
        startup_result: %{runtime: %{journal: %{path: journal_path}}}
      }),
      dir
    )

    assert ResumeSessions.journal_dir(%{}) == Path.join([File.cwd!(), ".ourocode", "journals"])
  end

  defp tmp_dir!(name) do
    path = Path.join(System.tmp_dir!(), "ourocode-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
