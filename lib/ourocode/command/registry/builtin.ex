defmodule Ourocode.Command.Registry.Builtin do
  @moduledoc """
  Builtin slash command definitions and normalization.
  """

  alias Ourocode.Command.RegistryEntryAdapter

  @builtin_definitions [
    %{
      name: "help",
      slash: "/help",
      aliases: ["/?"],
      category: :discovery,
      summary: "Show available commands and skills.",
      run_spec: %{kind: :builtin_action, action: :show_help}
    },
    %{
      name: "commands",
      slash: "/commands",
      aliases: ["/cmds"],
      category: :discovery,
      summary: "Show the main command list.",
      run_spec: %{kind: :builtin_action, action: :show_commands}
    },
    %{
      name: "skills",
      slash: "/skills",
      aliases: [],
      category: :discovery,
      summary: "Browse installed skills.",
      run_spec: %{kind: :builtin_action, action: :show_skills}
    },
    %{
      name: "capabilities",
      slash: "/capabilities",
      aliases: ["/caps"],
      category: :discovery,
      summary: "Show what commands can do before they run.",
      run_spec: %{kind: :builtin_action, action: :show_capabilities}
    },
    %{
      name: "preflight",
      slash: "/preflight",
      aliases: [],
      category: :discovery,
      summary: "Preview what a command would do before executing it.",
      args: [
        %{
          name: "command",
          required?: true,
          description: "Command-shaped input to resolve, such as /plugins"
        }
      ],
      run_spec: %{kind: :builtin_action, action: :show_preflight}
    },
    %{
      name: "verify",
      slash: "/verify",
      aliases: [],
      category: :discovery,
      summary: "Run product checks for startup, plugins, TTY, and guided work.",
      run_spec: %{kind: :builtin_action, action: :show_verify}
    },
    %{
      name: "approve",
      slash: "/approve",
      aliases: [],
      category: :runtime,
      summary:
        "Approve the pending auto workflow checkpoint and advance sandbox execution evidence.",
      run_spec: %{kind: :builtin_action, action: :approve_workflow}
    },
    %{
      name: "clear",
      slash: "/clear",
      aliases: [],
      category: :runtime,
      summary:
        "Clear the current terminal screen and prompt buffer without deleting journal history.",
      run_spec: %{kind: :builtin_action, action: :clear_screen}
    },
    %{
      name: "resume",
      slash: "/resume",
      aliases: [],
      category: :journal,
      summary: "List previous journaled sessions and reconnect to one.",
      args: [
        %{
          name: "session",
          required?: false,
          description: "Optional session or journal id to resume"
        }
      ],
      run_spec: %{kind: :builtin_action, action: :resume_session}
    },
    %{
      name: "exit",
      slash: "/exit",
      aliases: [],
      category: :runtime,
      summary: "Exit the terminal UI cleanly.",
      run_spec: %{kind: :builtin_action, action: :exit}
    },
    %{
      name: "quit",
      slash: "/quit",
      aliases: [],
      category: :runtime,
      summary: "Exit the terminal UI cleanly.",
      run_spec: %{kind: :builtin_action, action: :exit}
    },
    %{
      name: "status",
      slash: "/status",
      aliases: ["/health"],
      category: :runtime,
      summary: "Show app, plugin, and queue health.",
      run_spec: %{kind: :builtin_action, action: :show_status}
    },
    %{
      name: "pane",
      slash: "/pane",
      aliases: ["/focus"],
      category: :steering,
      summary: "Focus or open a terminal pane.",
      args: [%{name: "pane_id", required?: true, description: "Pane or work item id"}],
      run_spec: %{kind: :builtin_action, action: :focus_pane}
    },
    %{
      name: "children",
      slash: "/children",
      aliases: ["/child"],
      category: :steering,
      summary: "Show delegated work and steering targets.",
      run_spec: %{kind: :builtin_action, action: :show_children}
    },
    %{
      name: "agents",
      slash: "/agents",
      aliases: [],
      category: :steering,
      summary: "Show delegated agents, active tasks, and steering targets.",
      run_spec: %{kind: :builtin_action, action: :show_agents}
    },
    %{
      name: "queue",
      slash: "/queue",
      aliases: ["/notifications"],
      category: :visibility,
      summary: "Show queued notifications and overflow summaries.",
      run_spec: %{kind: :builtin_action, action: :show_queue}
    },
    %{
      name: "hooks",
      slash: "/hooks",
      aliases: [],
      category: :visibility,
      summary: "Show recent automation activity.",
      run_spec: %{kind: :builtin_action, action: :show_hooks}
    },
    %{
      name: "wonder",
      slash: "/wonder",
      aliases: [],
      category: :interaction,
      summary: "Show active questions and answer checkpoints.",
      run_spec: %{kind: :builtin_action, action: :show_wonder_tool}
    },
    %{
      name: "plugins",
      slash: "/plugins",
      aliases: [],
      category: :plugins,
      summary: "Show configured official and third-party plugins.",
      run_spec: %{kind: :builtin_action, action: :show_plugins}
    },
    %{
      name: "mcp",
      slash: "/mcp",
      aliases: [],
      category: :runtime,
      summary: "Show local connection and structured-work readiness.",
      run_spec: %{kind: :builtin_action, action: :show_mcp}
    },
    %{
      name: "mcps",
      slash: "/mcps",
      aliases: [],
      category: :runtime,
      summary: "Show connected tools and guided-work readiness.",
      run_spec: %{kind: :builtin_action, action: :show_mcps}
    },
    %{
      name: "sandbox",
      slash: "/sandbox",
      aliases: [],
      category: :runtime,
      summary: "Show project-bounded safety and approval posture.",
      run_spec: %{kind: :builtin_action, action: :show_sandbox}
    },
    %{
      name: "sessions",
      slash: "/sessions",
      aliases: [],
      category: :steering,
      summary: "Show active workspaces and steering targets.",
      run_spec: %{kind: :builtin_action, action: :show_sessions}
    },
    %{
      name: "config",
      slash: "/config",
      aliases: [],
      category: :plugins,
      summary: "Show plugin readiness and reload guidance.",
      run_spec: %{kind: :builtin_action, action: :show_config}
    },
    %{
      name: "provider",
      slash: "/provider",
      aliases: ["/providers"],
      category: :runtime,
      summary: "Pick the active main-session provider/backend.",
      run_spec: %{kind: :builtin_action, action: :select_provider}
    },
    %{
      name: "model",
      slash: "/model",
      aliases: ["/models"],
      category: :runtime,
      summary: "Show provider-specific model commands and slug selection status.",
      run_spec: %{kind: :builtin_action, action: :show_model_commands}
    },
    %{
      name: "theme",
      slash: "/theme",
      aliases: [],
      category: :runtime,
      summary: "Switch terminal colors between light, dark, or auto.",
      args: [
        %{
          name: "mode",
          required?: false,
          description: "light, dark, white, or auto"
        }
      ],
      run_spec: %{kind: :builtin_action, action: :set_theme}
    },
    %{
      name: "login",
      slash: "/login",
      aliases: ["/signin"],
      category: :runtime,
      summary: "Connect the main session to ChatGPT via Codex OAuth.",
      run_spec: %{kind: :builtin_action, action: :provider_login}
    },
    %{
      name: "logout",
      slash: "/logout",
      aliases: ["/signout"],
      category: :runtime,
      summary: "Disconnect the current model provider.",
      run_spec: %{kind: :builtin_action, action: :provider_logout}
    },
    %{
      name: "reload",
      slash: "/reload",
      aliases: [],
      category: :plugins,
      summary: "Reload plugins and commands.",
      run_spec: %{kind: :builtin_action, action: :reload_runtime_boundary}
    },
    %{
      name: "replay",
      slash: "/replay",
      aliases: [],
      category: :journal,
      summary: "Replay journaled terminal-visible state.",
      run_spec: %{kind: :builtin_action, action: :replay_journal}
    },
    %{
      name: "cancel",
      slash: "/cancel",
      aliases: ["/cancel-child"],
      category: :steering,
      summary: "Cancel the active interview or focused delegated task.",
      args: [
        %{
          name: "reason",
          required?: false,
          description: "Optional cancellation reason sent to the task"
        }
      ],
      run_spec: %{kind: :builtin_action, action: :cancel_focused_child}
    }
  ]

  @interrupt_definition %{
    name: "interrupt",
    slash: "/interrupt",
    aliases: ["/stop-child"],
    category: :steering,
    summary: "Interrupt the currently focused delegated task.",
    run_spec: %{kind: :builtin_action, action: :interrupt_focused_child}
  }

  @cancel_definition %{
    name: "cancel",
    slash: "/cancel",
    aliases: ["/cancel-child"],
    category: :steering,
    summary: "Cancel the active interview or focused delegated task.",
    args: [
      %{
        name: "reason",
        required?: false,
        description: "Optional cancellation reason sent to the task"
      }
    ],
    run_spec: %{kind: :builtin_action, action: :cancel_focused_child}
  }

  @spec entries() :: [map()]
  def entries do
    Enum.map(@builtin_definitions, &normalize!/1)
  end

  @spec interrupt_definition() :: map()
  def interrupt_definition, do: @interrupt_definition

  @spec cancel_definition() :: map()
  def cancel_definition, do: @cancel_definition

  @spec normalize!(map()) :: map()
  def normalize!(definition) do
    slash = definition |> Map.fetch!(:slash) |> normalize_slash()

    RegistryEntryAdapter.from_slash_command!(definition,
      id: "builtin:#{slash}",
      source: :builtin,
      source_id: "builtin",
      distribution: :builtin,
      category: Map.fetch!(definition, :category),
      run_spec: Map.fetch!(definition, :run_spec),
      availability: Map.get(definition, :availability, :available),
      metadata: %{introduced_in: :interactive_baseline},
      source_attribution: %{
        source: :builtin,
        source_id: "builtin",
        distribution: :builtin
      }
    )
  end

  defp normalize_slash(command) when is_binary(command) do
    command = String.trim(command)

    if String.starts_with?(command, "/") do
      command
    else
      "/#{command}"
    end
  end
end
