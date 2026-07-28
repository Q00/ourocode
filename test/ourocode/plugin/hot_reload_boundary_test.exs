defmodule Ourocode.Plugin.HotReloadBoundaryTest do
  use ExUnit.Case, async: false

  alias Ourocode.Plugin.HotReloadBoundary
  alias Ourocode.Plugin.Loader
  alias Ourocode.Plugin.MappingSignatureVerifier
  alias Ourocode.Plugin.ConfigSchema

  import Ourocode.Test.PathAssertions, only: [assert_same_path: 2]

  test "compiles changed plugin code and swaps the active registry without losing prior state" do
    key_id = "hot-reload-key"
    secret = "hot-reload-secret"
    plugin_path = tmp_plugin_dir!("hot-reload")
    module_name = "Ourocode.PluginHotReloadAction#{System.unique_integer([:positive])}"
    source_path = Path.join(plugin_path, "action.ex")

    File.write!(source_path, action_module_source(module_name))

    action_mapping =
      signed_mapping(
        official_plugin_identity(),
        %{"key" => "session.focus", "module" => module_name},
        key_id,
        secret
      )

    File.write!(
      Path.join(plugin_path, "capabilities.json"),
      Ourocode.Json.encode!(%{
        "capabilities" => ["steering_action_mapping"],
        "plugin" => %{"id" => "ouroboros-plugin", "trust_tier" => "official"},
        "action_mappings" => [action_mapping]
      })
    )

    {:ok, checksum} = Loader.checksum(plugin_path)
    state = HotReloadBoundary.new(%{actions: %{{:session, :open} => :previous_action}})

    assert {:ok, reloaded} =
             HotReloadBoundary.reload(state, plugin_path,
               allowed_roots: [plugin_path],
               compile_paths: [source_path],
               expected_checksum: checksum,
               official_mapping_signing_keys: %{key_id => secret},
               loaded_at_ms: 123,
               reason: :test_reload
             )

    action = reloaded.registry.actions[{:session, :focus}]

    assert reloaded.generation == 1
    assert reloaded.previous_registry.actions == %{{:session, :open} => :previous_action}
    assert reloaded.registry.actions[{:session, :open}] == :previous_action
    assert reloaded.loaded_at_ms == 123
    assert reloaded.reason == :test_reload
    assert function_exported?(action, :execute, 2)

    assert {:ok, %{hot_reloaded?: true, child_id: "child-hot-1"}} =
             action.execute(%{child_id: "child-hot-1"}, %{})
  end

  test "config hot reload preserves enabled state and unloads plugin mappings when disabled" do
    key_id = "hot-reload-disable-key"
    secret = "hot-reload-disable-secret"
    plugin_path = tmp_plugin_dir!("hot-reload-disable")
    module_name = "Ourocode.PluginHotReloadDisableAction#{System.unique_integer([:positive])}"
    source_path = Path.join(plugin_path, "action.ex")

    File.write!(source_path, action_module_source(module_name))

    action_mapping =
      signed_mapping(
        official_plugin_identity(),
        %{"key" => "session.focus", "module" => module_name},
        key_id,
        secret
      )

    File.write!(
      Path.join(plugin_path, "capabilities.json"),
      Ourocode.Json.encode!(%{
        "capabilities" => ["steering_action_mapping"],
        "plugin" => %{"id" => "ouroboros-plugin", "trust_tier" => "official"},
        "action_mappings" => [action_mapping]
      })
    )

    {:ok, checksum} = Loader.checksum(plugin_path)
    {:ok, enabled_config} = plugin_config(plugin_path, true, checksum)
    {:ok, disabled_config} = plugin_config(plugin_path, false, checksum)

    base_action = :runtime_owned_action
    state = HotReloadBoundary.new(%{actions: %{{:session, :open} => base_action}})

    assert {:ok, enabled_state} =
             HotReloadBoundary.reload_config(state, enabled_config,
               allowed_roots: [plugin_path],
               compile_paths: [source_path],
               official_mapping_signing_keys: %{key_id => secret},
               loaded_at_ms: 200
             )

    assert enabled_state.generation == 1
    assert enabled_state.plugin_config.enabled_plugins == ["ouroboros-plugin"]
    assert enabled_state.plugin_config.disabled_plugins == []
    assert enabled_state.plugin_config.plugins_by_id["ouroboros-plugin"].enabled? == true
    assert enabled_state.plugin_transitions == [enabled_transition(:unconfigured)]
    assert enabled_state.registry.actions[{:session, :open}] == base_action
    assert function_exported?(enabled_state.registry.actions[{:session, :focus}], :execute, 2)

    assert {:ok, disabled_state} =
             HotReloadBoundary.reload_config(enabled_state, disabled_config,
               allowed_roots: [plugin_path],
               loaded_at_ms: 300
             )

    assert disabled_state.generation == 2
    assert disabled_state.previous_registry.actions[{:session, :focus}]
    assert disabled_state.registry.actions == %{{:session, :open} => base_action}
    assert disabled_state.plugin_config.enabled_plugins == []
    assert disabled_state.plugin_config.disabled_plugins == ["ouroboros-plugin"]
    assert disabled_state.plugin_config.plugins_by_id["ouroboros-plugin"].enabled? == false
    assert disabled_state.plugin_transitions == [disabled_transition(:enabled)]
    assert disabled_state.loaded_at_ms == 300
  end

  test "config hot reload preserves disabled state and loads plugin when re-enabled" do
    key_id = "hot-reload-enable-key"
    secret = "hot-reload-enable-secret"
    plugin_path = tmp_plugin_dir!("hot-reload-enable")
    module_name = "Ourocode.PluginHotReloadEnableAction#{System.unique_integer([:positive])}"
    source_path = Path.join(plugin_path, "action.ex")

    File.write!(source_path, action_module_source(module_name))

    action_mapping =
      signed_mapping(
        official_plugin_identity(),
        %{"key" => "session.focus", "module" => module_name},
        key_id,
        secret
      )

    File.write!(
      Path.join(plugin_path, "capabilities.json"),
      Ourocode.Json.encode!(%{
        "capabilities" => ["steering_action_mapping"],
        "plugin" => %{"id" => "ouroboros-plugin", "trust_tier" => "official"},
        "action_mappings" => [action_mapping]
      })
    )

    {:ok, checksum} = Loader.checksum(plugin_path)
    {:ok, disabled_config} = plugin_config(plugin_path, false, checksum)
    {:ok, enabled_config} = plugin_config(plugin_path, true, checksum)

    state = HotReloadBoundary.new(%{actions: %{{:session, :open} => :runtime_owned_action}})

    assert {:ok, disabled_state} =
             HotReloadBoundary.reload_config(state, disabled_config,
               allowed_roots: [plugin_path],
               loaded_at_ms: 400
             )

    assert disabled_state.generation == 1
    assert disabled_state.registry.actions == %{{:session, :open} => :runtime_owned_action}
    assert disabled_state.plugin_transitions == [disabled_transition(:unconfigured)]

    assert {:ok, enabled_state} =
             HotReloadBoundary.reload_config(disabled_state, enabled_config,
               allowed_roots: [plugin_path],
               compile_paths: [source_path],
               official_mapping_signing_keys: %{key_id => secret},
               loaded_at_ms: 500
             )

    assert enabled_state.generation == 2
    assert enabled_state.plugin_config.enabled_plugins == ["ouroboros-plugin"]
    assert enabled_state.plugin_config.plugins_by_id["ouroboros-plugin"].enabled? == true
    assert enabled_state.plugin_transitions == [enabled_transition(:disabled)]
    assert function_exported?(enabled_state.registry.actions[{:session, :focus}], :execute, 2)
    assert enabled_state.registry.actions[{:session, :open}] == :runtime_owned_action
  end

  test "config hot reload captures plugin load failures as structured runtime state" do
    plugin_path = tmp_plugin_dir!("hot-reload-load-failure")
    missing_manifest_path = Path.join(plugin_path, "capabilities.json")
    {:ok, enabled_config} = plugin_config(plugin_path, true, String.duplicate("0", 64))
    state = HotReloadBoundary.new(%{actions: %{{:session, :open} => :runtime_owned_action}})

    assert {:ok, failed_state} =
             HotReloadBoundary.reload_config(state, enabled_config,
               allowed_roots: [plugin_path],
               loaded_at_ms: 600
             )

    failure = failed_state.plugin.load_error

    assert failed_state.generation == 1
    assert failed_state.reason == :plugin_config_load_failed
    assert failed_state.registry.actions == %{{:session, :open} => :runtime_owned_action}
    assert failed_state.previous_registry.actions == %{{:session, :open} => :runtime_owned_action}

    assert failed_state.plugin.id == "ouroboros-plugin"
    assert failed_state.plugin.enabled? == true
    assert failed_state.plugin.state == :load_failed
    assert failed_state.plugin.source == "official"
    assert failed_state.plugin.path == plugin_path

    assert failed_state.plugin.entrypoint == %{
             "path" => "capabilities.json",
             "type" => "manifest"
           }

    assert failed_state.plugin.load_error == failure

    assert_load_failure(failure, %{
      plugin_id: "ouroboros-plugin",
      state: :load_failed,
      reason: :missing_capability_manifest,
      message_body: "is missing required capability manifest at",
      plugin_path: plugin_path,
      manifest_path: missing_manifest_path,
      source: "official",
      trust_policy: %{"requires_explicit_approval" => false, "tier" => "official"},
      attempted_at_ms: 600
    })

    assert failed_state.plugin_config.failed_plugins == ["ouroboros-plugin"]
    assert failed_state.plugin_config.plugins_by_id["ouroboros-plugin"].load_error == failure
    assert failed_state.plugin_load_failures == [failure]

    assert failed_state.plugin_transitions == [
             %{
               plugin_id: "ouroboros-plugin",
               from: :unconfigured,
               to: :load_failed,
               action: :load_failed,
               loadable?: false,
               reason: :missing_capability_manifest,
               load_error: failure
             }
           ]

    assert {:ok, retried_failed_state} =
             HotReloadBoundary.reload_config(failed_state, enabled_config,
               allowed_roots: [plugin_path],
               loaded_at_ms: 601
             )

    assert [
             %{
               plugin_id: "ouroboros-plugin",
               from: :load_failed,
               to: :load_failed,
               action: :load_failed,
               loadable?: false,
               reason: :missing_capability_manifest
             }
           ] = retried_failed_state.plugin_transitions
  end

  test "config hot reload clears plugin error state after a failing plugin becomes valid" do
    plugin_path = tmp_plugin_dir!("hot-reload-recovery")
    {:ok, failing_config} = plugin_config(plugin_path, true, String.duplicate("0", 64))
    state = HotReloadBoundary.new(%{actions: %{{:session, :open} => :runtime_owned_action}})

    assert {:ok, failed_state} =
             HotReloadBoundary.reload_config(state, failing_config,
               allowed_roots: [plugin_path],
               loaded_at_ms: 800
             )

    failed_status = failed_state.plugin_config.plugins_by_id["ouroboros-plugin"]

    assert failed_status.state == :load_failed
    assert failed_state.plugin_config.failed_plugins == ["ouroboros-plugin"]
    assert [_failure] = failed_state.plugin_load_failures
    assert Map.has_key?(failed_status, :load_error)

    File.write!(
      Path.join(plugin_path, "capabilities.json"),
      Ourocode.Json.encode!(%{
        "capabilities" => [],
        "plugin" => %{"id" => "ouroboros-plugin", "trust_tier" => "official"}
      })
    )

    {:ok, recovered_checksum} = Loader.checksum(plugin_path)
    {:ok, recovered_config} = plugin_config(plugin_path, true, recovered_checksum)

    assert {:ok, recovered_state} =
             HotReloadBoundary.reload_config(failed_state, recovered_config,
               allowed_roots: [plugin_path],
               loaded_at_ms: 900
             )

    recovered_status = recovered_state.plugin_config.plugins_by_id["ouroboros-plugin"]

    assert recovered_state.generation == 2
    assert recovered_state.reason == :plugin_config_hot_reload
    assert recovered_state.registry.actions == %{{:session, :open} => :runtime_owned_action}
    assert recovered_state.plugin.plugin_id == "ouroboros-plugin"
    refute Map.has_key?(recovered_state.plugin, :load_error)
    assert recovered_status.state == :enabled
    refute Map.has_key?(recovered_status, :load_error)
    assert recovered_state.plugin_config.failed_plugins == []
    assert recovered_state.plugin_load_failures == []

    assert recovered_state.plugin_transitions == [
             %{
               plugin_id: "ouroboros-plugin",
               from: :load_failed,
               to: :enabled,
               action: :load_requested,
               loadable?: true,
               reason: :enabled_in_config
             }
           ]
  end

  test "config hot reload updates plugin error state after a valid plugin becomes failing" do
    plugin_path = tmp_plugin_dir!("hot-reload-valid-to-failing")

    File.write!(
      Path.join(plugin_path, "capabilities.json"),
      Ourocode.Json.encode!(%{
        "capabilities" => [],
        "plugin" => %{"id" => "ouroboros-plugin", "trust_tier" => "official"}
      })
    )

    {:ok, valid_checksum} = Loader.checksum(plugin_path)
    {:ok, valid_config} = plugin_config(plugin_path, true, valid_checksum)
    state = HotReloadBoundary.new(%{actions: %{{:session, :open} => :runtime_owned_action}})

    assert {:ok, valid_state} =
             HotReloadBoundary.reload_config(state, valid_config,
               allowed_roots: [plugin_path],
               loaded_at_ms: 1_000
             )

    valid_status = valid_state.plugin_config.plugins_by_id["ouroboros-plugin"]

    assert valid_state.generation == 1
    assert valid_state.plugin_config.failed_plugins == []
    assert valid_status.state == :enabled
    refute Map.has_key?(valid_status, :load_error)
    refute Map.has_key?(valid_state.plugin, :load_error)

    File.write!(Path.join(plugin_path, "capabilities.json"), Ourocode.Json.encode!(%{}))

    {:ok, failing_checksum} = Loader.checksum(plugin_path)
    {:ok, failing_config} = plugin_config(plugin_path, true, failing_checksum)

    assert {:ok, failed_state} =
             HotReloadBoundary.reload_config(valid_state, failing_config,
               allowed_roots: [plugin_path],
               loaded_at_ms: 1_100
             )

    failure = failed_state.plugin.load_error
    failed_status = failed_state.plugin_config.plugins_by_id["ouroboros-plugin"]

    assert failed_state.generation == 2
    assert failed_state.reason == :plugin_config_load_failed
    assert failed_state.registry.actions == %{{:session, :open} => :runtime_owned_action}
    assert failed_state.previous_registry.actions == %{{:session, :open} => :runtime_owned_action}

    assert failed_state.plugin.id == "ouroboros-plugin"
    assert failed_state.plugin.state == :load_failed
    assert failed_state.plugin.enabled? == true
    assert failed_state.plugin.load_error == failure

    assert failed_status.state == :load_failed
    assert failed_status.load_error == failure
    assert failed_state.plugin_config.failed_plugins == ["ouroboros-plugin"]
    assert failed_state.plugin_load_failures == [failure]

    assert_load_failure(failure, %{
      plugin_id: "ouroboros-plugin",
      state: :load_failed,
      reason: :invalid_capability_manifest_schema,
      message_body: "has an invalid capability manifest schema at",
      plugin_path: plugin_path,
      manifest_path: Path.join(plugin_path, "capabilities.json"),
      source: "official",
      trust_policy: %{"requires_explicit_approval" => false, "tier" => "official"},
      attempted_at_ms: 1_100
    })

    assert failed_state.plugin_transitions == [
             %{
               plugin_id: "ouroboros-plugin",
               from: :enabled,
               to: :load_failed,
               action: :load_failed,
               loadable?: false,
               reason: :invalid_capability_manifest_schema,
               load_error: failure
             }
           ]
  end

  test "config hot reload attributes load errors to the correct plugin when several plugins load" do
    loaded_plugin_path = tmp_plugin_dir!("hot-reload-loaded-plugin")
    failed_plugin_path = tmp_plugin_dir!("hot-reload-failed-plugin")
    failed_manifest_path = Path.join(failed_plugin_path, "capabilities.json")

    File.write!(
      Path.join(loaded_plugin_path, "capabilities.json"),
      Ourocode.Json.encode!(%{
        "capabilities" => [],
        "plugin" => %{"id" => "ouroboros-plugin", "trust_tier" => "official"}
      })
    )

    {:ok, loaded_checksum} = Loader.checksum(loaded_plugin_path)
    {:ok, config} = multi_plugin_config(loaded_plugin_path, loaded_checksum, failed_plugin_path)
    state = HotReloadBoundary.new(%{actions: %{{:session, :open} => :runtime_owned_action}})

    assert {:ok, reloaded_state} =
             HotReloadBoundary.reload_config(state, config,
               allowed_roots: [loaded_plugin_path, failed_plugin_path],
               loaded_at_ms: 700
             )

    failure = reloaded_state.plugin_config.plugins_by_id["vim-mode"].load_error

    assert reloaded_state.registry.actions == %{{:session, :open} => :runtime_owned_action}
    assert reloaded_state.plugin_config.enabled_plugins == ["ouroboros-plugin", "vim-mode"]
    assert reloaded_state.plugin_config.failed_plugins == ["vim-mode"]

    assert reloaded_state.plugin_config.plugins_by_id["ouroboros-plugin"].state == :enabled

    refute Map.has_key?(
             reloaded_state.plugin_config.plugins_by_id["ouroboros-plugin"],
             :load_error
           )

    assert reloaded_state.plugin_config.plugins_by_id["vim-mode"].state == :load_failed

    assert_load_failure(failure, %{
      plugin_id: "vim-mode",
      state: :load_failed,
      reason: :missing_capability_manifest,
      message_body: "is missing required capability manifest at",
      plugin_path: failed_plugin_path,
      manifest_path: failed_manifest_path,
      source: "third_party",
      trust_policy: %{"requires_explicit_approval" => true, "tier" => "community_code"},
      attempted_at_ms: 700
    })

    assert reloaded_state.plugin_load_failures == [failure]

    assert Enum.find(reloaded_state.plugin_transitions, &(&1.plugin_id == "ouroboros-plugin")) ==
             %{
               plugin_id: "ouroboros-plugin",
               from: :unconfigured,
               to: :enabled,
               action: :load_requested,
               loadable?: true,
               reason: :enabled_in_config
             }

    assert Enum.find(reloaded_state.plugin_transitions, &(&1.plugin_id == "vim-mode")) ==
             %{
               plugin_id: "vim-mode",
               from: :unconfigured,
               to: :load_failed,
               action: :load_failed,
               loadable?: false,
               reason: :missing_capability_manifest,
               load_error: failure
             }
  end

  defp tmp_plugin_dir!(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ourocode-hot-reload-test-#{name}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp action_module_source(module_name) do
    """
    defmodule #{module_name} do
      def execute(payload, _context) do
        {:ok, Map.put(payload, :hot_reloaded?, true)}
      end
    end
    """
  end

  defp plugin_config(plugin_path, enabled?, checksum) do
    ConfigSchema.parse("""
    {
      "plugins": [
        {
          "identity": {"id": "ouroboros-plugin", "version": "0.1.0"},
          "path": #{Ourocode.Json.encode!(plugin_path)},
          "entrypoint": {"type": "manifest", "path": "capabilities.json"},
          "enabled": #{enabled?},
          "source": "official",
          "expected_checksum": #{Ourocode.Json.encode!(checksum)},
          "permissions": {
            "filesystem": [#{Ourocode.Json.encode!(plugin_path)}],
            "network": [],
            "process": []
          }
        }
      ]
    }
    """)
  end

  defp multi_plugin_config(loaded_plugin_path, loaded_checksum, failed_plugin_path) do
    ConfigSchema.parse("""
    {
      "plugins": [
        {
          "identity": {"id": "ouroboros-plugin", "version": "0.1.0"},
          "path": #{Ourocode.Json.encode!(loaded_plugin_path)},
          "entrypoint": {"type": "manifest", "path": "capabilities.json"},
          "enabled": true,
          "source": "official",
          "expected_checksum": #{Ourocode.Json.encode!(loaded_checksum)},
          "permissions": {
            "filesystem": [#{Ourocode.Json.encode!(loaded_plugin_path)}],
            "network": [],
            "process": []
          }
        },
        {
          "identity": {"id": "vim-mode", "version": "0.1.0"},
          "path": #{Ourocode.Json.encode!(failed_plugin_path)},
          "entrypoint": {"type": "manifest", "path": "capabilities.json"},
          "enabled": true,
          "source": "third_party",
          "expected_checksum": #{Ourocode.Json.encode!(String.duplicate("0", 64))},
          "permissions": {
            "filesystem": [#{Ourocode.Json.encode!(failed_plugin_path)}],
            "network": [],
            "process": []
          }
        }
      ]
    }
    """)
  end

  defp enabled_transition(from) do
    %{
      plugin_id: "ouroboros-plugin",
      from: from,
      to: :enabled,
      action: :load_requested,
      loadable?: true,
      reason: :enabled_in_config
    }
  end

  defp disabled_transition(from) do
    action = if from == :enabled, do: :unload_requested, else: :skip_load

    %{
      plugin_id: "ouroboros-plugin",
      from: from,
      to: :disabled,
      action: action,
      loadable?: false,
      reason: :disabled_in_config
    }
  end

  defp assert_load_failure(failure, expected) do
    expected_message =
      "plugin #{inspect(failure.plugin_path)} #{expected.message_body} #{inspect(failure.manifest_path)}"

    assert Map.drop(failure, [:message, :plugin_path, :manifest_path]) ==
             Map.drop(expected, [:message_body, :plugin_path, :manifest_path])

    assert failure.message == expected_message
    assert_same_path(failure.plugin_path, expected.plugin_path)
    assert_same_path(failure.manifest_path, expected.manifest_path)
  end

  defp official_plugin_identity do
    %{
      plugin_id: "ouroboros-plugin",
      trust_classification: "official_trusted"
    }
  end

  defp signed_mapping(plugin, mapping, key_id, secret) do
    signature = MappingSignatureVerifier.sign(:action, plugin, mapping, secret)

    Map.put(mapping, "signature", %{
      "key_id" => key_id,
      "algorithm" => "hmac-sha256",
      "value" => signature
    })
  end
end
