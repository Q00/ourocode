defmodule Ourocode.Command.Registry.BuiltinTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.Registry.Builtin

  test "normalizes builtin commands into registry entries" do
    entries = Builtin.entries()

    assert Enum.map(entries, & &1.slash) == [
             "/help",
             "/commands",
             "/skills",
             "/capabilities",
             "/preflight",
             "/verify",
             "/approve",
             "/clear",
             "/resume",
             "/exit",
             "/quit",
             "/status",
             "/pane",
             "/children",
             "/agents",
             "/queue",
             "/hooks",
             "/wonder",
             "/plugins",
             "/mcp",
             "/mcps",
             "/sandbox",
             "/sessions",
             "/config",
             "/provider",
             "/model",
             "/theme",
             "/login",
             "/logout",
             "/reload",
             "/replay",
             "/cancel"
           ]

    assert Enum.all?(entries, &(&1.source == :builtin))

    assert Enum.map(Enum.filter(entries, &(&1.availability == :stub)), & &1.slash) == []

    assert Enum.all?(entries, fn entry ->
             entry.source == :builtin and
               entry.source_id == "builtin" and
               entry.type == :slash_command and
               entry.runnable? == true and
               String.starts_with?(entry.id, "builtin:/") and
               String.starts_with?(entry.slash, "/") and
               is_binary(entry.summary) and
               entry.run_spec.kind == :builtin_action
           end)

    assert Map.new(entries, &{&1.slash, {&1.availability, &1.run_spec.action}})
           |> Map.take([
             "/clear",
             "/resume",
             "/exit",
             "/quit",
             "/status",
             "/preflight",
             "/verify",
             "/approve",
             "/plugins",
             "/mcp",
             "/mcps",
             "/sandbox",
             "/agents",
             "/sessions",
             "/config",
             "/theme",
             "/cancel"
           ]) == %{
             "/clear" => {:available, :clear_screen},
             "/resume" => {:available, :resume_session},
             "/exit" => {:available, :exit},
             "/quit" => {:available, :exit},
             "/status" => {:available, :show_status},
             "/preflight" => {:available, :show_preflight},
             "/verify" => {:available, :show_verify},
             "/approve" => {:available, :approve_workflow},
             "/plugins" => {:available, :show_plugins},
             "/mcp" => {:available, :show_mcp},
             "/mcps" => {:available, :show_mcps},
             "/sandbox" => {:available, :show_sandbox},
             "/agents" => {:available, :show_agents},
             "/sessions" => {:available, :show_sessions},
             "/config" => {:available, :show_config},
             "/theme" => {:available, :set_theme},
             "/cancel" => {:available, :cancel_focused_child}
           }

    pane = Enum.find(entries, &(&1.slash == "/pane"))
    preflight = Enum.find(entries, &(&1.slash == "/preflight"))

    assert pane.category == :steering
    assert preflight.aliases == []
    assert preflight.summary == "Preview what a command would do before executing it."

    provider = Enum.find(entries, &(&1.slash == "/provider"))
    model = Enum.find(entries, &(&1.slash == "/model"))

    assert provider.aliases == ["/providers"]
    assert provider.run_spec.action == :select_provider
    assert provider.summary =~ "provider"
    assert provider.summary =~ "backend"

    assert model.aliases == ["/models"]
    assert model.run_spec.action == :show_model_commands
    assert model.summary =~ "model"
    refute model.summary =~ "backend"

    assert pane.args == [
             %{name: "pane_id", required?: true, description: "Pane or work item id"}
           ]
  end

  test "normalizes contextual action definitions with builtin metadata" do
    interrupt = Builtin.normalize!(Builtin.interrupt_definition())
    cancel = Builtin.normalize!(Builtin.cancel_definition())

    assert interrupt.slash == "/interrupt"
    assert interrupt.aliases == ["/stop-child"]
    assert interrupt.run_spec.action == :interrupt_focused_child
    assert interrupt.metadata.introduced_in == :interactive_baseline

    assert cancel.slash == "/cancel"
    assert cancel.aliases == ["/cancel-child"]

    assert cancel.args == [
             %{
               name: "reason",
               required?: false,
               description: "Optional cancellation reason sent to the task"
             }
           ]
  end
end
