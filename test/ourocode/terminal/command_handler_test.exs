defmodule Ourocode.Terminal.CommandHandlerTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal
  alias Ourocode.Terminal.CommandHandler
  alias Ourocode.Terminal.CommandInput
  alias Ourocode.Runtime.FocusState
  alias Ourocode.Terminal.FocusNavigation
  import Ourocode.Test.PathAssertions, only: [assert_same_path: 2]

  test "handle renders built-in help commands from the contextual registry" do
    {:ok, output} = StringIO.open("")
    state = state(output)

    assert {:ok, %{count: count}} =
             CommandHandler.handle(CommandInput.command_event("/help"), state)

    assert count > 0

    {_input, text} = StringIO.contents(output)
    assert text =~ "help"
    assert text =~ "/help"
    assert text =~ "/config"
    assert text =~ "/theme"
    assert text =~ "/verify"
    refute text =~ "[builtin/discovery]"
    refute text =~ "/wonder-tool"
  end

  test "handle renders product status and sessions" do
    {:ok, output} = StringIO.open("")

    state =
      state(output, %{
        startup_result: %{
          status: :healthy,
          runtime: %{
            status: :ready,
            journal: %{status: :ready},
            queued_notifications: %{pending_count: 2},
            hooks: %{event_count: 0},
            plugins: []
          }
        },
        pane_model: %{
          panes: %{
            "child-session:alpha" => %{
              kind: :child_session,
              child_id: "child-alpha"
            }
          }
        }
      })

    assert {:ok, %{status: :rendered}} =
             CommandHandler.handle(CommandInput.command_event("/status"), state)

    {_input, text} = StringIO.contents(output)
    assert text =~ "status"
    assert text =~ "tools 0 connected"
    refute text =~ "surface="
    refute text =~ "transports="
    assert text =~ "sessions: 1 active"
    assert text =~ "child-session:alpha"
    assert text =~ "target child-alpha"
  end

  test "handle renders children empty state" do
    {:ok, output} = StringIO.open("")

    assert {:ok, %{count: 0}} =
             CommandHandler.handle(CommandInput.command_event("/children"), state(output))

    {_input, text} = StringIO.contents(output)
    assert text =~ "sessions: 0 active"
    assert text =~ "no delegated work yet"
    assert text =~ "start with ooo pm <goal>"
    assert text =~ "ooo interview <goal>"
    assert text =~ "ooo auto <goal>"
  end

  test "handle returns typo suggestions for unknown commands" do
    {:ok, output} = StringIO.open("")

    assert {:error, {:unknown_command, "/capabilites", suggestions}} =
             CommandHandler.handle(CommandInput.command_event("/capabilites"), state(output))

    assert "/capabilities" in suggestions
  end

  test "handle lists and replays journaled resume sessions" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ourocode-command-handler-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    session_path = Path.join(dir, "session-alpha.jsonl")
    active_path = Path.join(dir, "active.jsonl")

    Journal.append!(session_path, %{
      type: :parent_call_started,
      event_seq: 1,
      parent_call_id: "parent-alpha",
      runtime_source: "test",
      transport: :streamable_http,
      occurred_at_ms: 1
    })

    {:ok, output} = StringIO.open("")
    state = state(output, %{journal_path: active_path})

    assert {:ok, %{sessions: [%{id: "session-alpha", event_count: 1}]}} =
             CommandHandler.handle(CommandInput.command_event("/resume"), state)

    assert {:ok, %{path: replayed_path, events: [_event]}} =
             CommandHandler.handle(CommandInput.command_event("/resume session-alpha"), state)

    assert_same_path(replayed_path, session_path)

    {_input, text} = StringIO.contents(output)
    assert text =~ "resume workspace"
    assert text =~ "latest Saved session"
    assert text =~ "record 1"
    assert text =~ "state 1 replay event"
    assert text =~ "resumed session-alpha: 1 events replayed"
  end

  defp state(output, attrs \\ %{}) do
    Map.merge(
      %{
        output: output,
        startup_result: %{status: :healthy},
        focus_state: FocusState.new(),
        pane_model: FocusNavigation.default_pane_model(),
        command_dispatch_options: %{},
        journal_path: nil
      },
      attrs
    )
  end
end
