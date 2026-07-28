defmodule Ourocode.Command.RegistryTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.Registry
  alias Ourocode.Command.RegistryEntryAdapter
  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Runtime.FocusState

  test "loads builtin ourocode commands into a normalized entry set" do
    assert {:ok, registry} = Registry.load_builtin()

    assert registry.status == :ready
    assert registry.sources == [:builtin]
    assert registry.loaded_count == length(registry.ordered)
    assert MapSet.new(registry.ordered, & &1.slash) == MapSet.new(Map.keys(registry.entries))

    assert {:ok, %{source: :builtin, run_spec: %{kind: :builtin_action}}} =
             Registry.fetch(registry, "/help")
  end

  test "resolves builtin aliases to their canonical command entries" do
    {:ok, registry} = Registry.load_builtin()

    assert {:ok, help} = Registry.fetch(registry, "/?")
    assert help.slash == "/help"

    assert {:ok, commands} = Registry.fetch(registry, "cmds")
    assert commands.slash == "/commands"

    assert {:ok, pane} = Registry.fetch(registry, "/focus")
    assert pane.slash == "/pane"

    assert {:ok, login} = Registry.fetch(registry, "/signin")
    assert login.slash == "/login"

    assert Registry.fetch(registry, "/nope-not-a-command") == :error
  end

  test "merges normalized slash commands and skills with deterministic source ordering" do
    {:ok, builtin_registry} = Registry.load_builtin()

    bundled_skill =
      RegistryEntryAdapter.from_skill_definition!(
        %{
          "id" => "bundled-z",
          "name" => "Bundled Z",
          "description" => "Bundled skill should sort before local and plugin entries."
        },
        id: "bundled_skill:bundled-z",
        source: :bundled_skill,
        source_id: "priv/skills",
        distribution: :bundled,
        run_kind: :bundled_skill
      )

    local_skill =
      RegistryEntryAdapter.from_skill_definition!(
        %{
          "id" => "local-alpha",
          "name" => "Local Alpha",
          "description" => "Local skill wins over plugin duplicates.",
          "aliases" => ["/local-a"]
        },
        id: "local_skill:local-alpha",
        source: :local,
        source_id: "/tmp/local-skills",
        distribution: :local,
        run_kind: :local_skill
      )

    plugin_command =
      RegistryEntryAdapter.from_slash_command!(
        %{
          "name" => "Plugin Beta",
          "slash" => "/plugin-beta",
          "summary" => "Plugin slash command stays queryable.",
          "aliases" => ["/beta-plugin"],
          "run_spec" => %{kind: :plugin_command, plugin_id: "vim-mode", action: "beta"}
        },
        id: "plugin:vim-mode:plugin-beta",
        source: :plugin,
        source_id: "vim-mode",
        distribution: :third_party,
        category: :plugins
      )

    duplicate_plugin_command =
      RegistryEntryAdapter.from_slash_command!(
        %{
          "name" => "Local Alpha Shadow",
          "slash" => "/local-alpha",
          "summary" => "Plugin command must not replace a higher-priority local skill.",
          "run_spec" => %{kind: :plugin_command, plugin_id: "vim-mode", action: "shadow"}
        },
        id: "plugin:vim-mode:local-alpha-shadow",
        source: :plugin,
        source_id: "vim-mode",
        distribution: :third_party,
        category: :plugins
      )

    input_order = [plugin_command, duplicate_plugin_command, local_skill, bundled_skill]
    reversed_input_order = Enum.reverse(input_order)

    assert {:ok, registry} = Registry.merge_normalized_entries(builtin_registry, input_order)

    assert {:ok, reversed_registry} =
             Registry.merge_normalized_entries(builtin_registry, reversed_input_order)

    assert Enum.map(registry.ordered, & &1.slash) ==
             Enum.map(reversed_registry.ordered, & &1.slash)

    assert Enum.map(registry.ordered, & &1.id) == Enum.map(reversed_registry.ordered, & &1.id)
    assert registry.sources == [:builtin, :bundled_skill, :local, :plugin]
    assert registry.loaded_count == builtin_registry.loaded_count + 3

    assert Enum.drop(registry.ordered, builtin_registry.loaded_count) |> Enum.map(& &1.slash) == [
             "/bundled-z",
             "/local-alpha",
             "/plugin-beta"
           ]

    assert {:ok, bundled} = Registry.fetch(registry, "/bundled-z")
    assert bundled.source == :bundled_skill
    assert bundled.run_spec.kind == :bundled_skill

    assert {:ok, local} = Registry.fetch(registry, "/local-a")
    assert local.slash == "/local-alpha"
    assert local.source == :local

    assert {:ok, plugin} = Registry.fetch(registry, "/beta-plugin")
    assert plugin.slash == "/plugin-beta"
    assert plugin.source == :plugin
    assert plugin.run_spec.kind == :plugin_command

    assert Registry.fetch(registry, "/local-alpha-shadow") == :error

    assert [
             %{
               reason: :slash_collision,
               source: :plugin,
               token: "/local-alpha",
               winner: %{source: :local, slash: "/local-alpha"},
               loser: %{source: :plugin, id: "plugin:vim-mode:local-alpha-shadow"}
             }
           ] = registry.duplicates
  end

  test "exposes child session actions only when focus resolves to a concrete child session" do
    {:ok, registry} = Registry.load_builtin()

    parent_context = %{
      focus_state: FocusState.new(),
      pane_model: %{panes: %{parent: %{id: :parent, kind: :parent_session}}, open: [:parent]}
    }

    assert {:ok, parent_registry} = Registry.expose_contextual_actions(registry, parent_context)
    assert Registry.fetch(parent_registry, "/interrupt") == :error
    assert Registry.fetch(parent_registry, "/stop-child") == :error

    assert {:ok, parent_cancel} = Registry.fetch(parent_registry, "/cancel")
    refute Map.get(parent_cancel.metadata, :contextual?, false)
    assert parent_cancel.run_spec == %{kind: :builtin_action, action: :cancel_focused_child}

    assert {:ok, parent_cancel_alias} = Registry.fetch(parent_registry, "/cancel-child")
    assert parent_cancel_alias.slash == "/cancel"

    child_pane_id = "child-session:interrupt-alpha"

    child_pane_model = %{
      panes: %{
        child_pane_id => %{
          id: child_pane_id,
          kind: :child_session,
          child_id: "interrupt-alpha",
          transport: :stdio
        },
        parent: %{id: :parent, kind: :parent_session}
      },
      open: [:parent, child_pane_id]
    }

    assert {:ok, child_focus_state, _event} =
             FocusState.focus_pane(FocusState.new(), child_pane_id, child_pane_model)

    assert {:ok, child_registry} =
             Registry.expose_contextual_actions(registry,
               focus_state: child_focus_state,
               pane_model: child_pane_model
             )

    assert {:ok, interrupt} = Registry.fetch(child_registry, "/interrupt")
    assert interrupt.source == :builtin
    assert interrupt.category == :steering
    assert interrupt.runnable? == true

    assert interrupt.run_spec == %{
             kind: :builtin_action,
             action: :interrupt_focused_child,
             target: :focused_child_session,
             child_session_id: "interrupt-alpha",
             child_pane_id: child_pane_id
           }

    assert interrupt.metadata.contextual? == true
    assert interrupt.metadata.requires_focused_child_session? == true
    assert interrupt.metadata.focused_child_session.session_id == "interrupt-alpha"
    assert interrupt.source_attribution.requires_focused_child_session? == true

    assert {:ok, alias_entry} = Registry.fetch(child_registry, "/stop-child")
    assert alias_entry.slash == "/interrupt"

    assert {:ok, cancel} = Registry.fetch(child_registry, "/cancel")
    assert cancel.source == :builtin
    assert cancel.category == :steering
    assert cancel.runnable? == true

    assert cancel.args == [
             %{
               name: "reason",
               required?: false,
               description: "Optional cancellation reason sent to the task"
             }
           ]

    assert cancel.run_spec == %{
             kind: :builtin_action,
             action: :cancel_focused_child,
             target: :focused_child_session,
             child_session_id: "interrupt-alpha",
             child_pane_id: child_pane_id
           }

    assert cancel.metadata.contextual? == true
    assert cancel.metadata.requires_focused_child_session? == true
    assert cancel.metadata.focused_child_session.session_id == "interrupt-alpha"
    assert cancel.source_attribution.requires_focused_child_session? == true

    assert {:ok, cancel_alias_entry} = Registry.fetch(child_registry, "/cancel-child")
    assert cancel_alias_entry.slash == "/cancel"

    assert Enum.map(child_registry.ordered, & &1.slash) == [
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
             "/cancel",
             "/interrupt"
           ]
  end

  test "does not expose child session actions for aggregate child pane focus" do
    {:ok, registry} = Registry.load_builtin()

    pane_model = %{
      panes: %{children: %{id: :children, kind: :child_sessions}},
      open: [:children]
    }

    assert {:ok, focus_state, _event} =
             FocusState.focus_pane(FocusState.new(), :children, pane_model)

    assert {:ok, contextual_registry} =
             Registry.expose_contextual_actions(registry,
               focus_state: focus_state,
               pane_model: pane_model
             )

    assert Registry.fetch(contextual_registry, "/interrupt") == :error
    assert {:ok, cancel} = Registry.fetch(contextual_registry, "/cancel")
    refute Map.get(cancel.metadata, :contextual?, false)
  end

  test "loads local skill directory commands into normalized command entries" do
    skill_root = unique_tmp_dir()
    skill_dir = Path.join(skill_root, "ship-it")
    File.mkdir_p!(skill_dir)

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: "ship-it"
    description: "Prepare a release checklist from the current repository state."
    mcp_tool: release_planner
    ---

    # Ship It
    """)

    assert [entry] = Registry.local_skill_entries(skill_root)

    assert entry.id == "local_skill:ship-it"
    assert entry.name == "ship-it"
    assert entry.slash == "/ship-it"
    assert entry.source == :local
    assert entry.source_id == Path.expand(skill_root)
    assert entry.type == :slash_command
    assert entry.category == :skills
    assert entry.summary == "Prepare a release checklist from the current repository state."
    assert entry.aliases == []
    assert entry.args == []
    assert entry.availability == :available
    assert entry.runnable? == true

    assert entry.run_spec == %{
             kind: :local_skill,
             skill_path: Path.expand(skill_dir),
             skill_file: Path.expand(Path.join(skill_dir, "SKILL.md")),
             mcp_tool: "release_planner"
           }

    assert entry.metadata.skill_path == Path.expand(skill_dir)
    assert entry.metadata.skill_file == Path.expand(Path.join(skill_dir, "SKILL.md"))
    assert entry.metadata.frontmatter_keys == ["description", "mcp_tool", "name"]
  after
    cleanup_tmp_dir()
  end

  test "loads bundled skill directory commands into normalized command entries" do
    bundled_root = unique_tmp_dir()
    skill_dir = Path.join(bundled_root, "journal-replay")
    File.mkdir_p!(skill_dir)

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: "journal-replay"
    description: "Replay journaled terminal state for the active session."
    mcp_tool: replay_journal
    ---

    # Journal Replay
    """)

    assert [entry] = Registry.bundled_skill_entries(bundled_root)

    assert entry.id == "bundled_skill:journal-replay"
    assert entry.name == "journal-replay"
    assert entry.slash == "/journal-replay"
    assert entry.source == :bundled_skill
    assert entry.source_id == Path.expand(bundled_root)
    assert entry.type == :slash_command
    assert entry.category == :skills
    assert entry.summary == "Replay journaled terminal state for the active session."
    assert entry.aliases == []
    assert entry.args == []
    assert entry.availability == :available
    assert entry.runnable? == true

    assert entry.run_spec == %{
             kind: :bundled_skill,
             skill_path: Path.expand(skill_dir),
             skill_file: Path.expand(Path.join(skill_dir, "SKILL.md")),
             mcp_tool: "replay_journal"
           }

    assert entry.metadata.skill_path == Path.expand(skill_dir)
    assert entry.metadata.skill_file == Path.expand(Path.join(skill_dir, "SKILL.md"))
    assert entry.metadata.distribution == :bundled
    assert entry.metadata.frontmatter_keys == ["description", "mcp_tool", "name"]
  after
    cleanup_tmp_dir()
  end

  test "merged registry includes local skill source without overriding builtins" do
    skill_root = unique_tmp_dir()

    File.mkdir_p!(Path.join(skill_root, "review"))

    File.write!(Path.join([skill_root, "review", "SKILL.md"]), """
    ---
    name: "review"
    description: "Review the current branch."
    ---
    """)

    File.mkdir_p!(Path.join(skill_root, "help"))

    File.write!(Path.join([skill_root, "help", "SKILL.md"]), """
    ---
    name: "help"
    description: "This local skill must not replace builtin help."
    ---
    """)

    assert {:ok, registry} = Registry.load(bundled_skill_dirs: [], skill_dirs: [skill_root])

    assert registry.status == :ready
    assert registry.sources == [:builtin, :local]
    assert registry.loaded_count == length(registry.ordered)

    assert {:ok, review} = Registry.fetch(registry, "/review")
    assert review.source == :local
    assert review.category == :skills
    assert review.run_spec.kind == :local_skill

    assert {:ok, help} = Registry.fetch(registry, "/help")
    assert help.source == :builtin
    assert help.summary == "Show available commands and skills."

    refute Enum.any?(registry.ordered, &(&1.source == :local and &1.slash == "/help"))

    File.mkdir_p!(Path.join(skill_root, "cmds"))

    File.write!(Path.join([skill_root, "cmds", "SKILL.md"]), """
    ---
    name: "cmds"
    description: "This local skill must not replace a builtin alias."
    ---
    """)

    assert {:ok, registry} = Registry.load(bundled_skill_dirs: [], skill_dirs: [skill_root])
    assert {:ok, commands} = Registry.fetch(registry, "/cmds")
    assert commands.source == :builtin
    assert commands.slash == "/commands"

    refute Enum.any?(registry.ordered, &(&1.source == :local and &1.slash == "/cmds"))

    assert Enum.any?(
             registry.duplicates,
             &(&1.token == "/cmds" and &1.winner.slash == "/commands")
           )
  after
    cleanup_tmp_dir()
  end

  test "merged registry reports duplicate commands and resolves same-source duplicates deterministically" do
    skill_root = unique_tmp_dir()

    File.mkdir_p!(Path.join(skill_root, "alpha"))

    File.write!(Path.join([skill_root, "alpha", "SKILL.md"]), """
    ---
    name: "dupe"
    description: "First deterministic duplicate winner."
    ---
    """)

    File.mkdir_p!(Path.join(skill_root, "beta"))

    File.write!(Path.join([skill_root, "beta", "SKILL.md"]), """
    ---
    name: "dupe"
    description: "Second deterministic duplicate loser."
    ---
    """)

    assert {:ok, registry} = Registry.load(bundled_skill_dirs: [], skill_dirs: [skill_root])

    assert {:ok, dupe} = Registry.fetch(registry, "/dupe")
    assert dupe.source == :local
    assert dupe.summary == "First deterministic duplicate winner."
    assert dupe.metadata.skill_path == Path.expand(Path.join(skill_root, "alpha"))

    assert Enum.count(registry.ordered, &(&1.slash == "/dupe")) == 1
    assert registry.duplicate_count == 1

    assert [
             %{
               reason: :slash_collision,
               source: :local,
               token: "/dupe",
               winner: %{metadata: %{skill_path: winner_path}},
               loser: %{metadata: %{skill_path: loser_path}}
             }
           ] = registry.duplicates

    assert winner_path == Path.expand(Path.join(skill_root, "alpha"))
    assert loser_path == Path.expand(Path.join(skill_root, "beta"))
  after
    cleanup_tmp_dir()
  end

  test "merged registry rejects command and skill entries with conflicting identifiers" do
    {:ok, builtin_registry} = Registry.load_builtin()

    local_skill =
      RegistryEntryAdapter.from_skill_definition!(
        %{
          "id" => "review-shared",
          "name" => "Review Skill",
          "slash" => "/review-skill",
          "description" => "Accepted local skill with the shared identifier."
        },
        id: "shared-command-skill-id",
        source: :local,
        source_id: "/tmp/local-skills",
        distribution: :local,
        run_kind: :local_skill
      )

    plugin_command =
      RegistryEntryAdapter.from_slash_command!(
        %{
          "name" => "Review Command",
          "slash" => "/review-command",
          "summary" => "Rejected plugin command with the same identifier.",
          "run_spec" => %{kind: :plugin_command, plugin_id: "reviewer", action: "review"}
        },
        id: "shared-command-skill-id",
        source: :plugin,
        source_id: "reviewer",
        distribution: :third_party,
        category: :plugins
      )

    assert {:ok, registry} =
             Registry.merge_normalized_entries(builtin_registry, [plugin_command, local_skill])

    assert {:ok, review_skill} = Registry.fetch(registry, "/review-skill")
    assert review_skill.source == :local
    assert review_skill.id == "shared-command-skill-id"

    assert Registry.fetch(registry, "/review-command") == :error
    assert registry.sources == [:builtin, :local]
    assert registry.duplicate_count == 1

    assert [
             %{
               reason: :id_collision,
               source: :plugin,
               token: "shared-command-skill-id",
               winner: %{source: :local, slash: "/review-skill"},
               loser: %{source: :plugin, slash: "/review-command"}
             }
           ] = registry.duplicates
  end

  test "merged registry resolves same-source identifier conflicts deterministically" do
    {:ok, builtin_registry} = Registry.load_builtin()

    alpha =
      RegistryEntryAdapter.from_slash_command!(
        %{
          name: "Plugin Alpha",
          slash: "/alpha-command",
          summary: "Alphabetically first command wins a same-source id conflict.",
          run_spec: %{kind: :plugin_command, plugin_id: "vim-mode", action: "alpha"}
        },
        id: "plugin:vim-mode:shared-action",
        source: :plugin,
        source_id: "vim-mode",
        distribution: :third_party,
        category: :plugins
      )

    beta =
      RegistryEntryAdapter.from_skill_definition!(
        %{
          "id" => "shared-action",
          "name" => "Plugin Beta",
          "slash" => "/beta-skill",
          "description" => "Alphabetically later skill loses the same-source id conflict."
        },
        id: "plugin:vim-mode:shared-action",
        source: :plugin,
        source_id: "vim-mode",
        distribution: :third_party,
        run_kind: :plugin_skill
      )

    assert {:ok, registry} = Registry.merge_normalized_entries(builtin_registry, [beta, alpha])

    assert {:ok, alpha_entry} = Registry.fetch(registry, "/alpha-command")
    assert alpha_entry.id == "plugin:vim-mode:shared-action"
    assert alpha_entry.source == :plugin

    assert Registry.fetch(registry, "/beta-skill") == :error
    assert registry.duplicate_count == 1

    assert [
             %{
               reason: :id_collision,
               source: :plugin,
               token: "plugin:vim-mode:shared-action",
               winner: %{slash: "/alpha-command"},
               loser: %{slash: "/beta-skill"}
             }
           ] = registry.duplicates
  end

  test "merged registry includes bundled skill source before local skills without overriding builtins" do
    bundled_root = unique_tmp_dir()
    local_root = unique_tmp_dir("local")

    File.mkdir_p!(Path.join(bundled_root, "ask-user"))

    File.write!(Path.join([bundled_root, "ask-user", "SKILL.md"]), """
    ---
    name: "ask-user"
    description: "Bundled wonderTool-style user interaction skill."
    ---
    """)

    File.mkdir_p!(Path.join(local_root, "review"))

    File.write!(Path.join([local_root, "review", "SKILL.md"]), """
    ---
    name: "review"
    description: "Review the current branch."
    ---
    """)

    File.mkdir_p!(Path.join(local_root, "ask-user"))

    File.write!(Path.join([local_root, "ask-user", "SKILL.md"]), """
    ---
    name: "ask-user"
    description: "This local skill must not replace the bundled skill."
    ---
    """)

    assert {:ok, registry} =
             Registry.load(bundled_skill_dirs: [bundled_root], skill_dirs: [local_root])

    assert registry.status == :ready
    assert registry.sources == [:builtin, :bundled_skill, :local]
    assert registry.loaded_count == length(registry.ordered)

    assert {:ok, ask_user} = Registry.fetch(registry, "/ask-user")
    assert ask_user.source == :bundled_skill
    assert ask_user.category == :skills
    assert ask_user.run_spec.kind == :bundled_skill

    assert {:ok, review} = Registry.fetch(registry, "/review")
    assert review.source == :local
    assert review.run_spec.kind == :local_skill

    refute Enum.any?(registry.ordered, &(&1.source == :local and &1.slash == "/ask-user"))
    assert registry.duplicate_count == 1

    assert [%{source: :local, token: "/ask-user", winner: %{source: :bundled_skill}}] =
             registry.duplicates
  after
    cleanup_tmp_dir()
  end

  test "aggregates builtin, bundled skill, and local skill commands into one command surface" do
    bundled_root = unique_tmp_dir("bundled")
    local_root = unique_tmp_dir("local")

    File.mkdir_p!(Path.join(bundled_root, "journal-replay"))

    File.write!(Path.join([bundled_root, "journal-replay", "SKILL.md"]), """
    ---
    name: "journal-replay"
    description: "Replay a session from the event journal."
    ---
    """)

    File.mkdir_p!(Path.join(local_root, "ship-it"))

    File.write!(Path.join([local_root, "ship-it", "SKILL.md"]), """
    ---
    name: "ship-it"
    description: "Prepare a local release checklist."
    mcp_tool: release_planner
    ---
    """)

    assert {:ok, registry} =
             Registry.load(bundled_skill_dirs: [bundled_root], skill_dirs: [local_root])

    assert registry.sources == [:builtin, :bundled_skill, :local]
    assert registry.loaded_count == length(registry.ordered)

    assert ["/help", "/commands", "/skills" | _] = Enum.map(registry.ordered, & &1.slash)
    assert Map.has_key?(registry.entries, "/journal-replay")
    assert Map.has_key?(registry.entries, "/ship-it")

    assert {:ok, help} = Registry.fetch(registry, "/help")
    assert {:ok, journal_replay} = Registry.fetch(registry, "/journal-replay")
    assert {:ok, ship_it} = Registry.fetch(registry, "/ship-it")

    assert help.source == :builtin
    assert help.run_spec.kind == :builtin_action

    assert journal_replay.source == :bundled_skill
    assert journal_replay.source_id == Path.expand(bundled_root)
    assert journal_replay.run_spec.kind == :bundled_skill
    assert journal_replay.summary == "Replay a session from the event journal."

    assert ship_it.source == :local
    assert ship_it.source_id == Path.expand(local_root)
    assert ship_it.run_spec.kind == :local_skill
    assert ship_it.run_spec.mcp_tool == "release_planner"
    assert ship_it.summary == "Prepare a local release checklist."

    assert [builtin_entry | _] = registry.ordered
    assert builtin_entry.source == :builtin

    assert Enum.find_index(registry.ordered, &(&1.slash == "/journal-replay")) <
             Enum.find_index(registry.ordered, &(&1.slash == "/ship-it"))
  after
    cleanup_tmp_dir()
  end

  test "default merged registry includes the bundled wonderTool skill source" do
    assert {:ok, registry} = Registry.load(skill_dirs: [])

    assert :bundled_skill in registry.sources
    assert {:ok, wonder_tool} = Registry.fetch(registry, "/wonder-tool")
    assert wonder_tool.source == :bundled_skill
    assert wonder_tool.run_spec.kind == :bundled_skill
    assert wonder_tool.metadata.distribution == :bundled
  end

  test "loads official Ouroboros plugin commands and skills into normalized command entries" do
    assert {:ok, plugin_config} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {
                     "id": "ouroboros-plugin",
                     "name": "Ouroboros",
                     "version": "0.1.0"
                   },
                   "path": "plugins/ouroboros",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "enabled": true,
                   "source": "official",
                   "permissions": {
                     "filesystem": ["plugins/ouroboros"],
                     "network": [],
                     "process": []
                   },
                   "provenance": {
                     "publisher": "ouroboros",
                     "distribution": "bundled"
                   },
                   "config": {
                     "commands": true,
                     "skills": true
                   }
                 }
               ]
             }
             """)

    assert plugin_entries = Registry.plugin_entries(plugin_config)
    assert Enum.map(plugin_entries, & &1.slash) == Enum.sort(Enum.map(plugin_entries, & &1.slash))
    assert Enum.any?(plugin_entries, &(&1.slash == "/ooo"))
    assert Enum.any?(plugin_entries, &(&1.slash == "/ouroboros-qa"))

    assert {:ok, registry} =
             Registry.load(bundled_skill_dirs: [], skill_dirs: [], plugin_config: plugin_config)

    assert registry.sources == [:builtin, :plugin]
    assert registry.loaded_count == length(registry.ordered)

    assert {:ok, ooo} = Registry.fetch(registry, "/ooo")
    assert ooo.source == :plugin
    assert ooo.source_id == "ouroboros-plugin"
    assert ooo.category == :plugins
    assert ooo.summary == "Run the official Ouroboros workflow surface."
    assert ooo.aliases == ["/ouroboros"]

    assert ooo.args == [
             %{
               name: "goal",
               required?: false,
               description: "Natural-language workflow goal"
             }
           ]

    assert ooo.run_spec == %{
             kind: :plugin_command,
             plugin_id: "ouroboros-plugin",
             plugin_path: "plugins/ouroboros",
             action: "workflow"
           }

    assert ooo.metadata.plugin_id == "ouroboros-plugin"
    assert ooo.metadata.plugin_source == "official"
    assert ooo.metadata.plugin_surface == :command
    assert ooo.metadata.command_namespace == "plugin:official:ouroboros"
    assert ooo.metadata.namespace_owner == :official_ouroboros
    assert ooo.metadata.loaded_from == "plugins/ouroboros"
    assert ooo.metadata.provenance == %{"publisher" => "ouroboros", "distribution" => "bundled"}
    assert ooo.metadata.trust_policy["tier"] == "official"

    assert ooo.source_attribution == %{
             source: :plugin,
             source_id: "ouroboros-plugin",
             plugin_id: "ouroboros-plugin",
             plugin_source: "official",
             plugin_surface: :command,
             command_namespace: "plugin:official:ouroboros",
             namespace_owner: :official_ouroboros,
             loaded_from: "plugins/ouroboros",
             provenance: %{"publisher" => "ouroboros", "distribution" => "bundled"},
             trust_policy: %{"tier" => "official", "requires_explicit_approval" => false},
             trust_evaluation: %{
               "trust_tier" => "official",
               "trust_classification" => "official_trusted",
               "plugin_id" => "ouroboros-plugin",
               "requires_explicit_approval" => false
             },
             package_identity: %{
               "id" => "ouroboros-plugin",
               "name" => "Ouroboros",
               "version" => "0.1.0",
               "publisher" => nil,
               "namespace" => nil,
               "package" => nil
             }
           }

    assert ooo.metadata.source_attribution == ooo.source_attribution

    assert {:ok, alias_entry} = Registry.fetch(registry, "/ouroboros")
    assert alias_entry.slash == "/ooo"

    assert {:ok, qa} = Registry.fetch(registry, "/ouroboros-qa")
    assert qa.source == :plugin
    assert qa.category == :skills

    assert qa.run_spec == %{
             kind: :plugin_skill,
             plugin_id: "ouroboros-plugin",
             plugin_path: "plugins/ouroboros",
             action: "ouroboros-qa",
             mcp_tool: "ouroboros_qa"
           }

    assert qa.metadata.plugin_surface == :skill
    assert qa.source_attribution.plugin_id == "ouroboros-plugin"
    assert qa.source_attribution.plugin_surface == :skill
    assert qa.source_attribution.plugin_source == "official"
    assert qa.source_attribution.command_namespace == "plugin:official:ouroboros"
    assert qa.source_attribution.namespace_owner == :official_ouroboros
    assert qa.metadata.source_attribution == qa.source_attribution
  end

  test "skips disabled official plugin command surface and accepts explicit third-party plugin command and skill lists" do
    assert {:ok, plugin_config} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "ouroboros-plugin", "version": "0.1.0"},
                   "path": "plugins/ouroboros",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "enabled": false,
                   "source": "official",
                   "permissions": {
                     "filesystem": ["plugins/ouroboros"],
                     "network": [],
                     "process": []
                   },
                   "config": {"commands": true, "skills": true}
                 },
                 {
                   "identity": {"id": "vim-mode", "version": "1.0.0"},
                   "path": "plugins/vim-mode",
                   "entrypoint": {"type": "executable", "command": "bin/vim-mode"},
                   "enabled": true,
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": ["bin/vim-mode"]
                   },
                   "provenance": {
                     "publisher": "community",
                     "repository": "https://example.invalid/vim-mode"
                   },
                   "config": {
                     "commands": [
                       {
                         "name": "vim-toggle",
                         "description": "Toggle vim-like terminal controls.",
                         "aliases": ["/vim"],
                         "action": "toggle_mode",
                         "args": [
                           {
                             "name": "mode",
                             "required": false,
                             "description": "Mode to activate"
                           }
                         ]
                       }
                     ],
                     "skills": [
                       {
                         "name": "vim-motion-help",
                         "slash": "/vim-help",
                         "description": "Show plugin-provided vim motion guidance.",
                         "aliases": ["/vim-motions"],
                         "mcp_tool": "vim_motion_help"
                       }
                     ]
                   }
                 }
               ]
             }
             """)

    assert {:ok, registry} =
             Registry.load(bundled_skill_dirs: [], skill_dirs: [], plugin_config: plugin_config)

    assert Registry.fetch(registry, "/ooo") == :error

    assert {:ok, vim_toggle} = Registry.fetch(registry, "/vim-toggle")
    assert vim_toggle.source == :plugin
    assert vim_toggle.source_id == "vim-mode"
    assert vim_toggle.category == :plugins
    assert vim_toggle.availability == :available
    assert vim_toggle.runnable? == true
    assert vim_toggle.metadata.plugin_source == "third_party"

    assert vim_toggle.metadata.provenance == %{
             "publisher" => "community",
             "repository" => "https://example.invalid/vim-mode"
           }

    assert vim_toggle.args == [
             %{name: "mode", required?: false, description: "Mode to activate"}
           ]

    assert vim_toggle.run_spec.kind == :plugin_command
    assert vim_toggle.run_spec.action == "toggle_mode"
    assert vim_toggle.run_spec.plugin_id == "vim-mode"
    assert vim_toggle.run_spec.plugin_path == "plugins/vim-mode"
    assert vim_toggle.source_attribution == vim_toggle.metadata.source_attribution
    assert vim_toggle.source_attribution.plugin_id == "vim-mode"
    assert vim_toggle.source_attribution.plugin_source == "third_party"
    assert vim_toggle.source_attribution.plugin_surface == :command
    assert vim_toggle.source_attribution.command_namespace == "plugin:third_party:vim-mode"
    assert vim_toggle.source_attribution.namespace_owner == :third_party_plugin
    assert vim_toggle.source_attribution.loaded_from == "plugins/vim-mode"

    assert vim_toggle.source_attribution.provenance == %{
             "publisher" => "community",
             "repository" => "https://example.invalid/vim-mode"
           }

    assert vim_toggle.source_attribution.trust_policy["tier"] == "community_code"

    assert {:ok, vim_alias} = Registry.fetch(registry, "/vim")
    assert vim_alias.slash == "/vim-toggle"

    assert {:ok, vim_help} = Registry.fetch(registry, "/vim-help")
    assert vim_help.source == :plugin
    assert vim_help.source_id == "vim-mode"
    assert vim_help.category == :skills
    assert vim_help.summary == "Show plugin-provided vim motion guidance."
    assert vim_help.availability == :available
    assert vim_help.runnable? == true

    assert vim_help.run_spec == %{
             kind: :plugin_skill,
             plugin_id: "vim-mode",
             plugin_path: "plugins/vim-mode",
             action: "vim-motion-help",
             mcp_tool: "vim_motion_help"
           }

    assert vim_help.metadata.plugin_surface == :skill
    assert vim_help.metadata.plugin_source == "third_party"
    assert vim_help.source_attribution == vim_help.metadata.source_attribution
    assert vim_help.source_attribution.plugin_id == "vim-mode"
    assert vim_help.source_attribution.plugin_source == "third_party"
    assert vim_help.source_attribution.plugin_surface == :skill
    assert vim_help.source_attribution.command_namespace == "plugin:third_party:vim-mode"
    assert vim_help.source_attribution.namespace_owner == :third_party_plugin
    assert vim_help.source_attribution.loaded_from == "plugins/vim-mode"

    assert {:ok, vim_motions_alias} = Registry.fetch(registry, "/vim-motions")
    assert vim_motions_alias.slash == "/vim-help"
  end

  test "third-party plugin commands and skills cannot claim official Ouroboros namespace" do
    assert {:ok, plugin_config} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "vim-mode", "version": "1.0.0"},
                   "path": "plugins/vim-mode",
                   "entrypoint": {"type": "executable", "command": "bin/vim-mode"},
                   "enabled": true,
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": ["bin/vim-mode"]
                   },
                   "config": {
                     "commands": [
                       {
                         "name": "ooo",
                         "slash": "/ooo",
                         "description": "Spoof the official workflow command.",
                         "action": "spoof"
                       },
                       {
                         "name": "vim-toggle",
                         "description": "Toggle vim controls.",
                         "aliases": ["/ouroboros"],
                         "action": "toggle"
                       },
                       {
                         "name": "vim-mode",
                         "description": "A valid third-party command.",
                         "action": "mode"
                       }
                     ],
                     "skills": [
                       {
                         "name": "ouroboros-qa",
                         "slash": "/ouroboros-qa",
                         "description": "Spoof the official QA skill.",
                         "mcp_tool": "spoof_qa"
                       },
                       {
                         "name": "vim-help",
                         "description": "A valid third-party skill.",
                         "mcp_tool": "vim_help"
                       }
                     ]
                   }
                 }
               ]
             }
             """)

    assert {:ok, registry} =
             Registry.load(bundled_skill_dirs: [], skill_dirs: [], plugin_config: plugin_config)

    assert Registry.fetch(registry, "/ooo") == :error
    assert Registry.fetch(registry, "/ouroboros") == :error
    assert Registry.fetch(registry, "/ouroboros-qa") == :error
    assert Registry.fetch(registry, "/vim-toggle") == :error

    assert {:ok, vim_mode} = Registry.fetch(registry, "/vim-mode")
    assert vim_mode.source == :plugin
    assert vim_mode.metadata.plugin_source == "third_party"
    assert vim_mode.metadata.command_namespace == "plugin:third_party:vim-mode"
    assert vim_mode.metadata.namespace_owner == :third_party_plugin

    assert vim_mode.metadata.source_attribution.command_namespace ==
             vim_mode.metadata.command_namespace

    assert {:ok, vim_help} = Registry.fetch(registry, "/vim-help")
    assert vim_help.metadata.plugin_surface == :skill
    assert vim_help.metadata.command_namespace == "plugin:third_party:vim-mode"

    assert Enum.map(registry.ordered, & &1.slash) == [
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
             "/cancel",
             "/vim-help",
             "/vim-mode"
           ]
  end

  test "loads MCP transport-provided user-invocable tools into runnable command entries" do
    mcp_discovery = %{
      transport: :stdio,
      server_id: "filesystem",
      discovered_from: "tools/list",
      tools: [
        %{
          "name" => "fs.search",
          "title" => "File Search",
          "description" => "Search files through the filesystem MCP server.",
          "aliases" => ["/fs"],
          "inputSchema" => %{
            "type" => "object",
            "required" => ["query"],
            "properties" => %{
              "query" => %{"type" => "string", "description" => "Search query"},
              "limit" => %{"type" => "integer", "description" => "Maximum results"}
            }
          },
          "annotations" => %{"userInvocable" => true}
        },
        %{
          "name" => "internal.refresh-index",
          "description" => "Internal maintenance task.",
          "annotations" => %{"user_invocable" => false}
        }
      ]
    }

    assert [entry] = Registry.mcp_entries(mcp_discovery)

    assert entry.id == "mcp:filesystem:fs.search"
    assert entry.name == "file-search"
    assert entry.slash == "/file-search"
    assert entry.source == :mcp
    assert entry.source_id == "filesystem"
    assert entry.type == :slash_command
    assert entry.category == :mcp
    assert entry.summary == "Search files through the filesystem MCP server."
    assert entry.aliases == ["/fs"]
    assert entry.availability == :available
    assert entry.runnable? == true

    assert entry.args == [
             %{name: "limit", required?: false, description: "Maximum results"},
             %{name: "query", required?: true, description: "Search query"}
           ]

    assert entry.run_spec == %{
             kind: :mcp_tool,
             transport: :stdio,
             server_id: "filesystem",
             tool_name: "fs.search",
             method: "tools/call",
             invocability: %{
               user_invocable?: true,
               source: :annotation_user_invocable,
               raw_value: true,
               runnable?: true,
               method: "tools/call"
             }
           }

    assert entry.source_attribution == %{
             source: :mcp,
             source_id: "filesystem",
             transport: :stdio,
             server_id: "filesystem",
             discovered_from: "tools/list"
           }

    assert entry.metadata.tool_name == "fs.search"
    assert entry.metadata.transport == :stdio
    assert entry.metadata.invocability == entry.run_spec.invocability
    assert entry.metadata.input_schema["required"] == ["query"]
    assert entry.metadata.source_attribution == entry.source_attribution
  end

  test "merged registry includes MCP entries after plugins and preserves builtin precedence" do
    mcp_entries = [
      %{
        "transport" => "streamable_http",
        "source_id" => "remote-tools",
        "tools" => [
          %{
            "name" => "remote.review",
            "description" => "Review through a remote MCP server.",
            "inputSchema" => %{
              "properties" => %{
                "path" => %{"description" => "Path to review"}
              }
            }
          },
          %{
            "name" => "help",
            "slash" => "/help",
            "description" => "Must not replace builtin help."
          }
        ]
      },
      %{
        transport: :sse,
        server_id: "agent-tools",
        entries: [
          %{
            name: "agent-summarize",
            description: "Summarize child agent output.",
            args: [%{name: "child_id", required?: true, description: "Child session id"}]
          }
        ]
      }
    ]

    assert {:ok, registry} =
             Registry.load(
               bundled_skill_dirs: [],
               skill_dirs: [],
               plugin_config: [],
               mcp_entries: mcp_entries
             )

    assert registry.sources == [:builtin, :mcp]
    assert {:ok, review} = Registry.fetch(registry, "/remote-review")
    assert review.source == :mcp
    assert review.source_id == "remote-tools"
    assert review.run_spec.transport == :streamable_http
    assert review.run_spec.tool_name == "remote.review"
    assert review.run_spec.invocability == review.metadata.invocability
    assert review.metadata.invocability.source == :default_user_invocable

    assert {:ok, summarize} = Registry.fetch(registry, "/agent-summarize")
    assert summarize.source == :mcp
    assert summarize.source_id == "agent-tools"
    assert summarize.run_spec.transport == :sse

    assert summarize.args == [
             %{name: "child_id", required?: true, description: "Child session id"}
           ]

    assert {:ok, help} = Registry.fetch(registry, "/help")
    assert help.source == :builtin
    refute Enum.any?(registry.ordered, &(&1.source == :mcp and &1.slash == "/help"))

    assert Enum.any?(
             registry.duplicates,
             &(&1.source == :mcp and &1.token == "/help" and &1.winner.source == :builtin)
           )

    assert registry.ordered |> Enum.filter(&(&1.source == :mcp)) |> Enum.map(& &1.slash) ==
             ["/agent-summarize", "/remote-review"]
  end

  test "adds dynamically discovered session skills into the loaded registry and makes them queryable" do
    assert {:ok, registry} = Registry.load(bundled_skill_dirs: [], skill_dirs: [])

    assert {:ok, registry} =
             Registry.add_dynamic_skills(registry, [
               %{
                 id: "session-skill-42",
                 name: "Live Refactor",
                 description: "Apply a refactor discovered during the active session.",
                 aliases: ["refactor-now"],
                 args: [
                   %{name: "target", required?: true, description: "File or module to refactor"}
                 ],
                 mcp_tool: "live_refactor",
                 source_id: "parent-session",
                 discovered_from: "skill-index-refresh"
               }
             ])

    assert registry.sources == [:builtin, :dynamic_skill]
    assert registry.loaded_count == length(registry.ordered)

    assert {:ok, skill} = Registry.fetch(registry, "/live-refactor")
    assert skill.source == :dynamic_skill
    assert skill.source_id == "parent-session"
    assert skill.category == :skills
    assert skill.summary == "Apply a refactor discovered during the active session."
    assert skill.aliases == ["/refactor-now"]
    assert skill.availability == :available
    assert skill.runnable? == true

    assert skill.args == [
             %{name: "target", required?: true, description: "File or module to refactor"}
           ]

    assert skill.run_spec == %{
             kind: :dynamic_skill,
             skill_id: "session-skill-42",
             discovered_from: "skill-index-refresh",
             mcp_tool: "live_refactor"
           }

    assert skill.source_attribution == %{
             source: :dynamic_skill,
             source_id: "parent-session",
             distribution: :dynamic,
             discovered_from: "skill-index-refresh"
           }

    assert skill.metadata.source_attribution == skill.source_attribution

    assert {:ok, alias_entry} = Registry.fetch(registry, "/refactor-now")
    assert alias_entry.slash == "/live-refactor"
  end

  test "incremental dynamic skill discovery preserves previously registered command and skill entries" do
    bundled_root = unique_tmp_dir("bundled")
    local_root = unique_tmp_dir("local")

    File.mkdir_p!(Path.join(bundled_root, "journal-replay"))

    File.write!(Path.join([bundled_root, "journal-replay", "SKILL.md"]), """
    ---
    name: "journal-replay"
    description: "Replay a session from the event journal."
    ---
    """)

    File.mkdir_p!(Path.join(local_root, "ship-it"))

    File.write!(Path.join([local_root, "ship-it", "SKILL.md"]), """
    ---
    name: "ship-it"
    description: "Prepare a local release checklist."
    ---
    """)

    assert {:ok, registry} =
             Registry.load(bundled_skill_dirs: [bundled_root], skill_dirs: [local_root])

    assert {:ok, registry} =
             Registry.add_dynamic_skills(registry, [
               %{
                 id: "session-skill-1",
                 name: "Live Refactor",
                 description: "Apply a refactor discovered during the active session.",
                 source_id: "parent-session"
               }
             ])

    entries_before_incremental_discovery = registry.entries
    aliases_before_incremental_discovery = registry.aliases
    ordered_before_incremental_discovery = registry.ordered
    loaded_count_before_incremental_discovery = registry.loaded_count

    assert {:ok, registry} =
             Registry.add_dynamic_skills(registry, [
               %{
                 id: "session-skill-2",
                 name: "Trace Hooks",
                 description: "Inspect hook lifecycle events discovered during the session.",
                 aliases: ["/trace-hook-events"],
                 source_id: "parent-session"
               },
               %{
                 id: "session-skill-conflict",
                 name: "ship-it",
                 description: "This discovered skill must not overwrite the local skill.",
                 source_id: "parent-session"
               },
               %{
                 id: "session-skill-alias-conflict",
                 name: "Shadow Commands",
                 description: "This discovered skill must not overwrite a builtin alias.",
                 aliases: ["/cmds"],
                 source_id: "parent-session"
               }
             ])

    Enum.each(entries_before_incremental_discovery, fn {slash, entry} ->
      assert Map.fetch!(registry.entries, slash) == entry
    end)

    Enum.each(aliases_before_incremental_discovery, fn {alias, slash} ->
      assert Map.fetch!(registry.aliases, alias) == slash
    end)

    assert Enum.take(registry.ordered, length(ordered_before_incremental_discovery)) ==
             ordered_before_incremental_discovery

    assert registry.loaded_count == loaded_count_before_incremental_discovery + 1

    assert {:ok, help} = Registry.fetch(registry, "/help")
    assert help.source == :builtin

    assert {:ok, ship_it} = Registry.fetch(registry, "/ship-it")
    assert ship_it.source == :local
    assert ship_it.summary == "Prepare a local release checklist."

    assert {:ok, live_refactor} = Registry.fetch(registry, "/live-refactor")
    assert live_refactor.source == :dynamic_skill
    assert live_refactor.summary == "Apply a refactor discovered during the active session."

    assert {:ok, trace_hooks} = Registry.fetch(registry, "/trace-hooks")
    assert trace_hooks.source == :dynamic_skill
    assert trace_hooks.summary == "Inspect hook lifecycle events discovered during the session."

    assert {:ok, trace_hooks_by_alias} = Registry.fetch(registry, "/trace-hook-events")
    assert trace_hooks_by_alias.slash == "/trace-hooks"

    assert Registry.fetch(registry, "/shadow-commands") == :error
    assert Registry.fetch(registry, "/cmds") == Registry.fetch(registry, "/commands")

    assert Enum.any?(
             registry.duplicates,
             &(&1.source == :dynamic_skill and &1.token == "/ship-it" and
                 &1.winner.source == :local)
           )

    assert Enum.any?(
             registry.duplicates,
             &(&1.source == :dynamic_skill and &1.reason == :alias_collision and
                 &1.token == "/cmds" and &1.winner.source == :builtin)
           )
  after
    cleanup_tmp_dir()
  end

  test "resolve reports canonical and alias matches without changing fetch behavior" do
    {:ok, registry} = Registry.load_builtin()

    assert {:ok, canonical} = Registry.resolve(registry, "commands")

    assert canonical == %{
             entry: elem(Registry.fetch(registry, "/commands"), 1),
             token: "/commands",
             canonical: "/commands",
             match: :canonical
           }

    assert {:ok, alias_match} = Registry.resolve(registry, "cmds")
    assert alias_match.entry.slash == "/commands"
    assert alias_match.token == "/cmds"
    assert alias_match.canonical == "/commands"
    assert alias_match.match == :alias

    assert Registry.resolve(registry, "/missing") == :error
    assert Registry.fetch(registry, "/cmds") == {:ok, alias_match.entry}
  end

  defp unique_tmp_dir(suffix \\ "root") do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ourocode-command-registry-#{suffix}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    Process.put(:registry_tmp_dirs, [dir | Process.get(:registry_tmp_dirs, [])])
    dir
  end

  defp cleanup_tmp_dir do
    Process.get(:registry_tmp_dirs, [])
    |> Enum.each(&File.rm_rf!/1)

    Process.delete(:registry_tmp_dirs)
  end
end
