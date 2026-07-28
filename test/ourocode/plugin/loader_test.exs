defmodule Ourocode.Plugin.LoaderTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.LoadError
  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Plugin.Loader

  test "parses enabled official plugin definitions into normalized status records" do
    config_path =
      tmp_config_file!("official-config-status", """
      {
        "plugins": [
          {
            "identity": {"id": "ouroboros-plugin", "version": "0.1.0"},
            "path": "plugins/ouroboros",
            "entrypoint": {"type": "manifest", "path": "capabilities.json"},
            "enabled": true,
            "source": "official",
            "permissions": {
              "filesystem": ["plugins/ouroboros"],
              "network": [],
              "process": []
            }
          },
          {
            "identity": {"id": "vim-mode", "version": "1.4.2"},
            "path": "plugins/vim-mode",
            "entrypoint": {"type": "executable", "command": "bin/vim-mode"},
            "enabled": false,
            "permissions": {
              "filesystem": [],
              "network": [],
              "process": ["bin/vim-mode"]
            }
          }
        ]
      }
      """)

    assert {:ok,
            %{
              status: :ready,
              plugins: [
                %{
                  plugin_id: "ouroboros-plugin",
                  source_type: "official",
                  version: "0.1.0",
                  enabled?: true,
                  load_state: :load_requested,
                  path: "plugins/ouroboros"
                },
                %{
                  plugin_id: "vim-mode",
                  source_type: "third_party",
                  version: "1.4.2",
                  enabled?: false,
                  load_state: :disabled,
                  path: "plugins/vim-mode"
                }
              ],
              enabled_official_plugins: [
                %{
                  plugin_id: "ouroboros-plugin",
                  source_type: "official",
                  version: "0.1.0",
                  enabled?: true,
                  load_state: :load_requested
                }
              ],
              enabled_third_party_plugins: []
            }} = Loader.load_config_file(config_path)
  end

  test "parses enabled third-party plugin definitions into normalized status records" do
    config_path =
      tmp_config_file!("third-party-config-status", """
      {
        "plugins": [
          {
            "identity": {
              "id": "vim-mode",
              "publisher": "community",
              "version": "1.4.2"
            },
            "path": "plugins/vim-mode",
            "entrypoint": {"type": "executable", "command": "bin/vim-mode"},
            "enabled": true,
            "source": "third_party",
            "permissions": {
              "filesystem": [],
              "network": [],
              "process": ["bin/vim-mode"]
            }
          },
          {
            "identity": {
              "id": "statusline",
              "publisher": "community",
              "version": "0.3.1"
            },
            "path": "plugins/statusline",
            "entrypoint": {"type": "manifest", "path": "capabilities.json"},
            "enabled": false,
            "source": "third_party",
            "permissions": {
              "filesystem": [],
              "network": [],
              "process": []
            }
          }
        ]
      }
      """)

    assert {:ok,
            %{
              status: :ready,
              plugins: [
                %{
                  plugin_id: "vim-mode",
                  source_type: "third_party",
                  version: "1.4.2",
                  enabled?: true,
                  load_state: :load_requested,
                  path: "plugins/vim-mode"
                },
                %{
                  plugin_id: "statusline",
                  source_type: "third_party",
                  version: "0.3.1",
                  enabled?: false,
                  load_state: :disabled,
                  path: "plugins/statusline"
                }
              ],
              enabled_official_plugins: [],
              enabled_third_party_plugins: [
                %{
                  plugin_id: "vim-mode",
                  source_type: "third_party",
                  version: "1.4.2",
                  enabled?: true,
                  load_state: :load_requested,
                  path: "plugins/vim-mode"
                }
              ]
            }} = Loader.load_config_file(config_path)
  end

  test "builds normalized status records from an already parsed plugin config" do
    assert {:ok, %ConfigSchema{} = config} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "ouroboros-plugin", "version": "0.2.0"},
                   "path": "plugins/ouroboros",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "source": "official",
                   "permissions": {
                     "filesystem": ["plugins/ouroboros"],
                     "network": [],
                     "process": []
                   }
                 }
               ]
             }
             """)

    assert Loader.config_status_report(config) == %{
             status: :ready,
             plugins: [
               %{
                 plugin_id: "ouroboros-plugin",
                 source_type: "official",
                 version: "0.2.0",
                 enabled?: true,
                 load_state: :load_requested,
                 path: "plugins/ouroboros"
               }
             ],
             enabled_official_plugins: [
               %{
                 plugin_id: "ouroboros-plugin",
                 source_type: "official",
                 version: "0.2.0",
                 enabled?: true,
                 load_state: :load_requested,
                 path: "plugins/ouroboros"
               }
             ],
             enabled_third_party_plugins: []
           }
  end

  test "rejects a plugin when the capability manifest is missing" do
    plugin_path = tmp_plugin_dir!("missing-manifest")

    assert {:error,
            %LoadError{
              reason: :missing_capability_manifest,
              plugin_path: expanded_path,
              manifest_path: manifest_path
            }} = Loader.load(plugin_path, allowed_roots: [plugin_path])

    assert expanded_path == Path.expand(plugin_path)
    assert manifest_path == Path.join(Path.expand(plugin_path), "capabilities.json")
  end

  test "rejects a plugin when the expected checksum is missing" do
    plugin_path = tmp_plugin_dir!("missing-checksum")
    manifest_path = Path.join(plugin_path, "capabilities.json")

    File.write!(
      manifest_path,
      ~s({"capabilities":[],"plugin":{"id":"ouroboros-plugin","trust_tier":"official"}})
    )

    assert {:error,
            %LoadError{
              reason: :missing_plugin_checksum,
              plugin_path: expanded_path,
              manifest_path: ^manifest_path
            }} = Loader.load(plugin_path, allowed_roots: [plugin_path])

    assert expanded_path == Path.expand(plugin_path)
  end

  test "accepts a plugin when the capability manifest exists and checksum matches" do
    plugin_path = tmp_plugin_dir!("with-manifest")
    manifest_path = Path.join(plugin_path, "capabilities.json")

    File.write!(
      manifest_path,
      ~s({"capabilities":[],"plugin":{"id":"ouroboros-plugin","trust_tier":"official"}})
    )

    {:ok, expected_checksum} = Loader.checksum(plugin_path)

    assert {:ok,
            %{
              plugin_path: expanded_path,
              capability_manifest_path: ^manifest_path,
              capability_manifest: %{
                "capabilities" => [],
                "plugin" => %{"id" => "ouroboros-plugin", "trust_tier" => "official"}
              },
              checksum: ^expected_checksum,
              trust_tier: "official",
              trust_classification: "official_trusted",
              plugin_id: "ouroboros-plugin"
            }} =
             Loader.load(plugin_path,
               allowed_roots: [plugin_path],
               expected_checksum: expected_checksum
             )

    assert expanded_path == Path.expand(plugin_path)
  end

  test "accepts a plugin when the computed checksum matches the expected checksum" do
    plugin_path = tmp_plugin_dir!("matching-checksum")
    manifest_path = Path.join(plugin_path, "capabilities.json")
    renderer_path = Path.join(plugin_path, "renderer.json")

    File.write!(
      manifest_path,
      ~s({"capabilities":["pane_renderer"],"plugin":{"id":"ouroboros-plugin","trust_tier":"official"}})
    )

    File.write!(renderer_path, ~s({"renderer":"compact"}))
    {:ok, expected_checksum} = Loader.checksum(plugin_path)

    assert {:ok,
            %{
              plugin_path: expanded_path,
              capability_manifest_path: ^manifest_path,
              capability_manifest: %{
                "capabilities" => ["pane_renderer"],
                "plugin" => %{"id" => "ouroboros-plugin", "trust_tier" => "official"}
              },
              checksum: ^expected_checksum,
              trust_tier: "official",
              trust_classification: "official_trusted",
              plugin_id: "ouroboros-plugin"
            }} =
             Loader.load(plugin_path,
               allowed_roots: [plugin_path],
               expected_checksum: expected_checksum
             )

    assert expanded_path == Path.expand(plugin_path)
  end

  test "rejects a plugin when the computed checksum differs from the expected checksum" do
    plugin_path = tmp_plugin_dir!("mismatched-checksum")
    manifest_path = Path.join(plugin_path, "capabilities.json")
    renderer_path = Path.join(plugin_path, "renderer.json")
    File.write!(manifest_path, ~s({"capabilities":["pane_renderer"]}))
    File.write!(renderer_path, ~s({"renderer":"compact"}))
    {:ok, _actual_checksum} = Loader.checksum(plugin_path)

    assert {:error,
            %LoadError{
              reason: :plugin_checksum_mismatch,
              plugin_path: expanded_path,
              manifest_path: ^manifest_path
            }} =
             Loader.load(plugin_path,
               allowed_roots: [plugin_path],
               expected_checksum: String.duplicate("0", 64)
             )

    assert expanded_path == Path.expand(plugin_path)
  end

  test "rejects a plugin when the capability manifest fails schema validation" do
    plugin_path = tmp_plugin_dir!("invalid-manifest-schema")
    manifest_path = Path.join(plugin_path, "capabilities.json")
    File.write!(manifest_path, ~s({"capabilities":"all"}))

    assert {:error,
            %LoadError{
              reason: :invalid_capability_manifest_schema,
              plugin_path: expanded_path,
              manifest_path: ^manifest_path
            }} = Loader.load(plugin_path, allowed_roots: [plugin_path])

    assert expanded_path == Path.expand(plugin_path)
  end

  test "rejects a community-code plugin without an explicit trusted approval record" do
    plugin_path = tmp_plugin_dir!("community-missing-trust")
    manifest_path = Path.join(plugin_path, "capabilities.json")

    File.write!(
      manifest_path,
      ~s({"capabilities":["pane_renderer"],"trust_tier":"community_code"})
    )

    {:ok, expected_checksum} = Loader.checksum(plugin_path)

    assert {:error,
            %LoadError{
              reason: :missing_community_plugin_trust_approval,
              plugin_path: expanded_path,
              manifest_path: ^manifest_path
            }} =
             Loader.load(plugin_path,
               allowed_roots: [plugin_path],
               expected_checksum: expected_checksum
             )

    assert expanded_path == Path.expand(plugin_path)
  end

  test "rejects a community-code plugin when the trust approval is not explicit" do
    plugin_path = tmp_plugin_dir!("community-unapproved-trust")
    manifest_path = Path.join(plugin_path, "capabilities.json")

    File.write!(
      manifest_path,
      ~s({"capabilities":["pane_renderer"],"trust_tier":"community-code"})
    )

    {:ok, expected_checksum} = Loader.checksum(plugin_path)

    approval = %{
      plugin_path: Path.expand(plugin_path),
      checksum: expected_checksum,
      trust_tier: "community-code",
      approved: false
    }

    assert {:error,
            %LoadError{
              reason: :missing_community_plugin_trust_approval,
              plugin_path: expanded_path,
              manifest_path: ^manifest_path
            }} =
             Loader.load(plugin_path,
               allowed_roots: [plugin_path],
               expected_checksum: expected_checksum,
               trusted_approvals: [approval]
             )

    assert expanded_path == Path.expand(plugin_path)
  end

  test "accepts a community-code plugin when an explicit trusted approval record matches" do
    plugin_path = tmp_plugin_dir!("community-with-trust")
    manifest_path = Path.join(plugin_path, "capabilities.json")

    File.write!(
      manifest_path,
      ~s({"capabilities":["pane_renderer"],"trust_tier":"community_code"})
    )

    {:ok, expected_checksum} = Loader.checksum(plugin_path)

    approval = %{
      plugin_path: Path.expand(plugin_path),
      checksum: expected_checksum,
      trust_tier: "community_code",
      approved: true
    }

    assert {:ok,
            %{
              plugin_path: expanded_path,
              capability_manifest_path: ^manifest_path,
              capability_manifest: %{
                "capabilities" => ["pane_renderer"],
                "trust_tier" => "community_code"
              },
              checksum: ^expected_checksum,
              trust_tier: "community_code",
              trust_approval: ^approval
            }} =
             Loader.load(plugin_path,
               allowed_roots: [plugin_path],
               expected_checksum: expected_checksum,
               trusted_approvals: [approval]
             )

    assert expanded_path == Path.expand(plugin_path)
  end

  test "rejects a community-code plugin when prior trust approval has been revoked" do
    plugin_path = tmp_plugin_dir!("community-revoked-trust")
    manifest_path = Path.join(plugin_path, "capabilities.json")

    File.write!(
      manifest_path,
      ~s({"capabilities":["pane_renderer"],"trust_tier":"community_code"})
    )

    {:ok, expected_checksum} = Loader.checksum(plugin_path)
    expanded_plugin_path = Path.expand(plugin_path)

    prior_approval = %{
      plugin_path: expanded_plugin_path,
      checksum: expected_checksum,
      trust_tier: "community_code",
      approved: true
    }

    revocation = %{
      plugin_path: expanded_plugin_path,
      checksum: expected_checksum,
      trust_tier: "community_code",
      approved: true,
      revoked: true
    }

    assert {:error,
            %LoadError{
              reason: :revoked_community_plugin_trust_approval,
              plugin_path: ^expanded_plugin_path,
              manifest_path: ^manifest_path
            }} =
             Loader.load(plugin_path,
               allowed_roots: [plugin_path],
               expected_checksum: expected_checksum,
               trusted_approvals: [prior_approval, revocation]
             )
  end

  test "rejects a plugin from a disallowed root before loading its manifest" do
    denied_root = tmp_plugin_dir!("denied-root")
    allowed_root = tmp_plugin_dir!("allowed-root")
    plugin_path = Path.join(denied_root, "community-plugin")
    File.mkdir_p!(plugin_path)
    File.write!(Path.join(plugin_path, "capabilities.json"), ~s({"capabilities":[]}))

    assert {:error,
            %LoadError{
              reason: :plugin_path_not_allowed,
              plugin_path: ^plugin_path,
              manifest_path: nil
            }} = Loader.load(plugin_path, allowed_roots: [allowed_root])
  end

  test "rejects denied paths before manifest path resolution" do
    denied_root = tmp_plugin_dir!("denied-before-manifest")
    allowed_root = tmp_plugin_dir!("allowed-before-manifest")
    plugin_path = Path.join(denied_root, "community-plugin")

    assert {:error,
            %LoadError{
              reason: :plugin_path_not_allowed,
              plugin_path: ^plugin_path,
              manifest_path: nil
            }} =
             Loader.load(plugin_path,
               allowed_roots: [allowed_root],
               manifest_filename: nil
             )
  end

  defp tmp_plugin_dir!(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-plugin-loader-test-#{name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)

    on_exit(fn ->
      File.rm_rf!(path)
    end)

    Path.expand(path)
  end

  defp tmp_config_file!(name, contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-plugin-loader-test-#{name}-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, contents)

    on_exit(fn ->
      File.rm(path)
    end)

    path
  end
end
