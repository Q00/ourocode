defmodule Ourocode.Plugin.ConfigWatcherTest do
  use ExUnit.Case, async: false

  alias Ourocode.Journal
  alias Ourocode.Plugin.ConfigWatcher
  import Ourocode.Test.PathAssertions, only: [path_key: 1]

  test "detects plugin config create modify and delete and emits reload requests without UI restart" do
    project_dir = tmp_dir!("plugin-config-watcher")
    config_path = Path.join(project_dir, ".ourocode/config.json")
    journal_path = Path.join(project_dir, ".ourocode/journals/watcher.jsonl")
    File.mkdir_p!(Path.dirname(config_path))
    File.mkdir_p!(Path.dirname(journal_path))

    {:ok, watcher} =
      ConfigWatcher.start_link(
        project_dir: project_dir,
        source_paths: [config_path],
        poll_interval_ms: false,
        subscribers: [self()],
        journal_path: journal_path,
        watcher_id: "watcher-test"
      )

    assert {:ok, []} = ConfigWatcher.poll(watcher)

    File.write!(config_path, plugin_config_json("ouroboros-plugin", true))
    assert {:ok, [created]} = ConfigWatcher.poll(watcher)
    assert_reload_request(created, :created, config_path)
    assert created.ui_restart_required? == false
    assert_receive {:plugin_config_reload_requested, ^created}

    File.write!(config_path, plugin_config_json("ouroboros-plugin", false))
    assert {:ok, [modified]} = ConfigWatcher.poll(watcher)
    assert_reload_request(modified, :modified, config_path)
    assert modified.ui_restart_required? == false
    assert_receive {:plugin_config_reload_requested, ^modified}

    File.rm!(config_path)
    assert {:ok, [deleted]} = ConfigWatcher.poll(watcher)
    assert_reload_request(deleted, :deleted, config_path)
    assert deleted.ui_restart_required? == false
    assert_receive {:plugin_config_reload_requested, ^deleted}

    watcher_state = ConfigWatcher.state(watcher)
    assert Process.alive?(watcher)
    assert watcher_state.ui_process_restart_count == 0
    assert watcher_state.emitted_count == 3

    assert {:ok, replayed} = Journal.read_ordered(journal_path)
    assert Enum.map(replayed, & &1.type) == List.duplicate(:plugin_config_reload_requested, 3)
    assert Enum.map(replayed, & &1.change) == [:created, :modified, :deleted]
    assert Enum.all?(replayed, &(&1.source == :plugin_config_watcher))
    assert Enum.all?(replayed, &(&1.reload_boundary == :elixir_runtime))
    assert Enum.all?(replayed, &(&1.ui_restart_required? == false))
  end

  test "uses supported project config candidates so missing sources can later be created" do
    project_dir = tmp_dir!("plugin-config-candidates")

    paths = ConfigWatcher.source_paths(project_dir)
    path_keys = Enum.map(paths, &path_key/1)
    project_dir_key = path_key(project_dir)

    assert path_key(Path.join(project_dir, ".ourocode/config.json")) in path_keys
    assert path_key(Path.join(project_dir, "ourocode.json")) in path_keys
    assert Enum.all?(path_keys, &String.starts_with?(&1, project_dir_key))
  end

  test "manual polling ignores unrelated file create modify and delete changes without reload events" do
    project_dir = tmp_dir!("plugin-config-ignore-unrelated")
    config_path = Path.join(project_dir, ".ourocode/config.json")

    unrelated_paths = [
      Path.join(project_dir, ".ourocode/notes.md"),
      Path.join(project_dir, "plugins/vim-mode/capabilities.json"),
      Path.join(project_dir, "README.md")
    ]

    journal_path = Path.join(project_dir, ".ourocode/journals/watcher.jsonl")
    File.mkdir_p!(Path.dirname(config_path))
    File.mkdir_p!(Path.dirname(journal_path))
    Enum.each(unrelated_paths, &File.mkdir_p!(Path.dirname(&1)))

    {:ok, watcher} =
      ConfigWatcher.start_link(
        project_dir: project_dir,
        poll_interval_ms: false,
        subscribers: [self()],
        journal_path: journal_path,
        watcher_id: "watcher-ignore-unrelated-test"
      )

    assert {:ok, []} = ConfigWatcher.poll(watcher)

    Enum.each(unrelated_paths, &File.write!(&1, "unrelated create\n"))
    assert_no_reload_emitted(watcher, journal_path)

    Enum.each(unrelated_paths, &File.write!(&1, "unrelated modify\n"))
    assert_no_reload_emitted(watcher, journal_path)

    Enum.each(unrelated_paths, &File.rm!(&1))
    assert_no_reload_emitted(watcher, journal_path)
  end

  test "automatic polling emits reload events for relevant config files only" do
    project_dir = tmp_dir!("plugin-config-auto-poll")
    config_path = Path.join(project_dir, ".ourocode/config.json")
    irrelevant_path = Path.join(project_dir, "README.md")
    journal_path = Path.join(project_dir, ".ourocode/journals/watcher.jsonl")
    File.mkdir_p!(Path.dirname(config_path))
    File.mkdir_p!(Path.dirname(journal_path))

    {:ok, watcher} =
      ConfigWatcher.start_link(
        project_dir: project_dir,
        poll_interval_ms: 20,
        subscribers: [self()],
        journal_path: journal_path,
        watcher_id: "watcher-auto-poll-test"
      )

    File.write!(irrelevant_path, "not a watched config source\n")
    refute_receive {:plugin_config_reload_requested, _event}, 80

    File.write!(config_path, plugin_config_json("ouroboros-plugin", true))
    assert_receive {:plugin_config_reload_requested, created}, 500

    assert_reload_request(created, :created, config_path)
    assert created.relevance == :relevant_config_change
    assert created.relevant? == true
    assert created.ui_restart_required? == false

    assert %{emitted_count: 1, last_reload_requests: [^created]} = ConfigWatcher.state(watcher)

    assert {:ok, [journaled]} = Journal.read_ordered(journal_path)
    assert journaled.type == :plugin_config_reload_requested
    assert journaled.change == :created
    assert journaled.config_source_path == Path.expand(config_path)
  end

  test "integration: plugin-scoped settings changes emit typed hot reload events" do
    project_dir = tmp_dir!("plugin-settings-hot-reload")
    config_path = Path.join(project_dir, ".ourocode/config.json")
    settings_path = Path.join(project_dir, "plugins/vim-mode/settings.json")
    journal_path = Path.join(project_dir, ".ourocode/journals/plugin-settings.jsonl")

    File.mkdir_p!(Path.dirname(config_path))
    File.mkdir_p!(Path.dirname(settings_path))
    File.mkdir_p!(Path.dirname(journal_path))
    File.write!(config_path, plugin_config_json("ouroboros-plugin", true))

    {:ok, watcher} =
      ConfigWatcher.start_link(
        project_dir: project_dir,
        source_paths: [config_path],
        plugin_setting_paths: [%{plugin_id: "vim-mode", path: settings_path}],
        poll_interval_ms: false,
        subscribers: [self()],
        journal_path: journal_path,
        watcher_id: "watcher-plugin-settings-test"
      )

    assert {:ok, []} = ConfigWatcher.poll(watcher)

    File.write!(settings_path, Ourocode.Json.encode!(%{"mode" => "normal"}))
    assert {:ok, [created]} = ConfigWatcher.poll(watcher)
    assert_plugin_settings_reload_request(created, :created, settings_path)
    assert_receive {:plugin_settings_reload_requested, ^created}

    File.write!(settings_path, Ourocode.Json.encode!(%{"mode" => "insert"}))
    assert {:ok, [modified]} = ConfigWatcher.poll(watcher)
    assert_plugin_settings_reload_request(modified, :modified, settings_path)
    assert_receive {:plugin_settings_reload_requested, ^modified}

    File.rm!(settings_path)
    assert {:ok, [deleted]} = ConfigWatcher.poll(watcher)
    assert_plugin_settings_reload_request(deleted, :deleted, settings_path)
    assert_receive {:plugin_settings_reload_requested, ^deleted}

    state = ConfigWatcher.state(watcher)
    assert state.ui_process_restart_count == 0
    assert state.emitted_count == 3

    assert state.plugin_setting_paths == [
             %{kind: :plugin_settings, plugin_id: "vim-mode", path: Path.expand(settings_path)}
           ]

    assert {:ok, replayed} = Journal.read_ordered(journal_path)
    assert Enum.map(replayed, & &1.type) == List.duplicate(:plugin_settings_reload_requested, 3)

    assert Enum.map(replayed, & &1.event_type) ==
             List.duplicate(:plugin_settings_reload_requested, 3)

    assert Enum.map(replayed, & &1.change) == [:created, :modified, :deleted]
    assert Enum.all?(replayed, &(&1.plugin_id == "vim-mode"))
    assert Enum.all?(replayed, &(&1.reason == :plugin_scoped_settings_changed))
    assert Enum.all?(replayed, &(&1.relevance == :relevant_plugin_settings_change))
    assert Enum.all?(replayed, &(&1.reload_boundary == :elixir_runtime))
    assert Enum.all?(replayed, &(&1.ui_restart_required? == false))
    assert Enum.all?(replayed, &(&1.settings_source_path == Path.expand(settings_path)))
  end

  test "snapshot diff classifies create modify and delete transitions" do
    path = Path.expand("/tmp/ourocode-plugin-config-watcher-test.json")

    before = [%{path: path, exists?: false}]
    created = [%{path: path, exists?: true, size: 10, mtime: 1, checksum: "a"}]
    modified = [%{path: path, exists?: true, size: 11, mtime: 1, checksum: "b"}]
    deleted = [%{path: path, exists?: false}]

    assert ConfigWatcher.diff_snapshots(before, created) == [{:created, hd(created)}]
    assert ConfigWatcher.diff_snapshots(created, modified) == [{:modified, hd(modified)}]
    assert ConfigWatcher.diff_snapshots(modified, deleted) == [{:deleted, hd(deleted)}]
    assert ConfigWatcher.diff_snapshots(deleted, deleted) == []
  end

  test "watched config file transitions are classified as relevant changes" do
    project_dir = tmp_dir!("plugin-config-relevance")
    config_path = Path.join(project_dir, ".ourocode/config.json")
    File.mkdir_p!(Path.dirname(config_path))

    {:ok, watcher} =
      ConfigWatcher.start_link(
        project_dir: project_dir,
        source_paths: [config_path],
        poll_interval_ms: false,
        watcher_id: "watcher-relevance-test"
      )

    assert {:ok, []} = ConfigWatcher.poll(watcher)

    File.write!(config_path, plugin_config_json("ouroboros-plugin", true))
    assert {:ok, [created]} = ConfigWatcher.poll(watcher)
    assert created.change == :created
    assert created.relevance == :relevant_config_change
    assert created.relevant? == true

    assert {:ok, []} = ConfigWatcher.poll(watcher)

    File.write!(config_path, plugin_config_json("ouroboros-plugin", false))
    assert {:ok, [modified]} = ConfigWatcher.poll(watcher)
    assert modified.change == :modified
    assert modified.relevance == :relevant_config_change
    assert modified.relevant? == true

    File.rm!(config_path)
    assert {:ok, [deleted]} = ConfigWatcher.poll(watcher)
    assert deleted.change == :deleted
    assert deleted.relevance == :relevant_config_change
    assert deleted.relevant? == true
  end

  defp assert_reload_request(event, change, config_path) do
    assert event.type == :plugin_config_reload_requested
    assert event.event_type == :plugin_config_reload_requested
    assert event.source == :plugin_config_watcher
    assert event.change == change
    assert event.relevance == :relevant_config_change
    assert event.relevant? == true
    assert event.reason == :plugin_config_source_changed
    assert event.config_source_path == Path.expand(config_path)
    assert event.config_source_relative_path == ".ourocode/config.json"
    assert event.reload_boundary == :elixir_runtime
    assert is_integer(event.occurred_at_ms)
    assert is_binary(event.request_id)
  end

  defp assert_plugin_settings_reload_request(event, change, settings_path) do
    assert event.type == :plugin_settings_reload_requested
    assert event.event_type == :plugin_settings_reload_requested
    assert event.source == :plugin_config_watcher
    assert event.change == change
    assert event.relevance == :relevant_plugin_settings_change
    assert event.relevant? == true
    assert event.reason == :plugin_scoped_settings_changed
    assert event.plugin_id == "vim-mode"
    assert event.settings_source_path == Path.expand(settings_path)
    assert event.settings_source_relative_path == "plugins/vim-mode/settings.json"
    assert event.reload_boundary == :elixir_runtime
    assert event.ui_restart_required? == false
    assert is_integer(event.occurred_at_ms)
    assert is_binary(event.request_id)
    assert String.starts_with?(event.request_id, "plugin-settings-reload:")
  end

  defp assert_no_reload_emitted(watcher, journal_path) do
    assert {:ok, []} = ConfigWatcher.poll(watcher)
    refute_receive {:plugin_config_reload_requested, _event}, 20
    assert %{emitted_count: 0, last_reload_requests: []} = ConfigWatcher.state(watcher)
    refute File.exists?(journal_path)
  end

  defp plugin_config_json(plugin_id, enabled?) do
    Ourocode.Json.encode!(%{
      "plugins" => [
        %{
          "identity" => %{"id" => plugin_id, "version" => "0.1.0"},
          "path" => "plugins/ouroboros",
          "entrypoint" => %{"type" => "manifest", "path" => "capabilities.json"},
          "enabled" => enabled?,
          "source" => "official",
          "permissions" => %{"filesystem" => [], "network" => [], "process" => []}
        }
      ]
    })
  end

  defp tmp_dir!(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ourocode-#{name}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end
end
