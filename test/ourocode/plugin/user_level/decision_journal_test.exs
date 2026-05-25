defmodule Ourocode.Plugin.UserLevel.DecisionJournalTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.UserLevel.Capability
  alias Ourocode.Plugin.UserLevel.DecisionJournal
  alias Ourocode.Plugin.UserLevel.PreflightResult

  defp collect_events do
    pid = self()
    {pid, fn event -> send(pid, {:journal_event, event}); :ok end}
  end

  defp preflight do
    {:ok, capability} =
      Capability.new(%{
        plugin_id: "superpowers",
        source: :fixture,
        trust_scope: ["filesystem:read"],
        commands: [%{name: "list"}]
      })

    %PreflightResult{
      kind: :unique_match,
      task_input: "ooo superpowers list",
      plugin: capability,
      command: hd(capability.commands),
      args: [],
      trust_state: :allowed,
      risk_class: :read_only
    }
  end

  test "log_preflight/3 emits a user_level_preflight event with projected payload" do
    {_pid, writer} = collect_events()

    assert :ok = DecisionJournal.log_preflight(writer, "task-1", preflight())

    assert_received {:journal_event, event}
    assert event["event_type"] == "user_level_preflight"
    assert event["task_request_id"] == "task-1"
    assert is_integer(event["recorded_at_ms"])
    assert %{"preflight" => %{"kind" => "unique_match"}} = event["payload"]
  end

  test "log_dispatch/3 includes status, command, argv, plugin_id" do
    {_pid, writer} = collect_events()

    envelope = %{
      status: :invoked,
      command: "ouroboros",
      argv: ["superpowers", "list"],
      execution: %{status: 0},
      preflight: preflight()
    }

    assert :ok = DecisionJournal.log_dispatch(writer, "task-1", envelope)

    assert_received {:journal_event, event}
    assert event["event_type"] == "user_level_dispatch"
    assert event["payload"]["status"] == "invoked"
    assert event["payload"]["command"] == "ouroboros"
    assert event["payload"]["argv"] == ["superpowers", "list"]
    assert event["payload"]["execution_status"] == 0
  end

  test "log_artifacts/3 emits one event per artifact" do
    {_pid, writer} = collect_events()

    artifacts = [
      %{kind: :seed, path: "/tmp/seed.md", glob: ".omx/*/seed.md", size: 12},
      %{kind: :handoff, path: "/tmp/handoff.md", glob: ".omx/*/handoff.md"}
    ]

    assert :ok = DecisionJournal.log_artifacts(writer, "task-1", artifacts)

    assert_received {:journal_event, %{"event_type" => "user_level_artifact"} = first}
    assert_received {:journal_event, %{"event_type" => "user_level_artifact"} = second}
    refute_received {:journal_event, _}

    paths = Enum.map([first, second], & &1["payload"]["path"]) |> Enum.sort()
    assert paths == ["/tmp/handoff.md", "/tmp/seed.md"]
  end

  test "log_artifacts/3 with empty list is a no-op" do
    {_pid, writer} = collect_events()
    assert :ok = DecisionJournal.log_artifacts(writer, "task-1", [])
    refute_received {:journal_event, _}
  end

  test "log_continuation/3 captures action + seed_path + reason" do
    {_pid, writer} = collect_events()

    decision = %{
      action: :suggest,
      seed_path: "/tmp/seed.md",
      command_template: "ooo run seed_path=/tmp/seed.md",
      reason: :user_confirmation_required
    }

    assert :ok = DecisionJournal.log_continuation(writer, "task-1", decision)

    assert_received {:journal_event, event}
    assert event["event_type"] == "user_level_continuation"
    assert event["payload"]["action"] == "suggest"
    assert event["payload"]["seed_path"] == "/tmp/seed.md"
    assert event["payload"]["reason"] == "user_confirmation_required"
  end

  test "invalid journal target returns structured error" do
    assert {:error, :invalid_journal_target} =
             DecisionJournal.log_preflight(:not_callable, "task", preflight())
  end
end
