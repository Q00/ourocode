defmodule Ourocode.Plugin.RendererMappingLoaderTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.LoadError
  alias Ourocode.Plugin.Loader
  alias Ourocode.Plugin.MappingSignatureVerifier
  alias Ourocode.Plugin.RendererMappingLoader
  import Ourocode.Test.PathAssertions

  defmodule OfficialChildRenderer do
    def render(%{kind: :child_session, child_id: child_id, pane_state: pane_state}) do
      entries = Map.get(pane_state, :stream_entries, [])

      %{
        id: "rendered-#{child_id}",
        title: "Official child #{child_id}",
        line: "child=#{child_id} entries=#{length(entries)}"
      }
    end
  end

  test "loads signed official ouroboros-plugin renderer mappings into a runnable registry" do
    key_id = "official-renderer-key"
    secret = "official-renderer-secret"
    plugin_path = tmp_plugin_dir!("official-renderer-mapping")
    manifest_path = Path.join(plugin_path, "capabilities.json")
    plugin_identity = official_plugin_identity()

    renderer_mapping =
      signed_mapping(
        :renderer,
        plugin_identity,
        %{
          "key" => "child_session",
          "module" => inspect(OfficialChildRenderer)
        },
        key_id,
        secret
      )

    File.write!(
      manifest_path,
      Ourocode.Json.encode!(%{
        "capabilities" => ["pane_renderer"],
        "plugin" => %{"id" => "ouroboros-plugin", "trust_tier" => "official"},
        "renderer_mappings" => [renderer_mapping]
      })
    )

    {:ok, expected_checksum} = Loader.checksum(plugin_path)

    assert {:ok,
            %{
              plugin: %{
                plugin_id: "ouroboros-plugin",
                trust_classification: "official_trusted",
                checksum: ^expected_checksum
              },
              renderer_mappings: [
                mapping = %{
                  "key" => "child_session",
                  "module" => module_name
                }
              ],
              renderers: renderers = %{child_session: OfficialChildRenderer}
            }} =
             RendererMappingLoader.load_default(plugin_path,
               allowed_roots: [plugin_path],
               expected_checksum: expected_checksum,
               official_mapping_signing_keys: %{key_id => secret}
             )

    assert module_name == inspect(OfficialChildRenderer)

    assert %{
             "algorithm" => "hmac-sha256",
             "key_id" => ^key_id,
             "value" => signature
           } = mapping["signature"]

    assert is_binary(signature)

    pane = %{
      kind: :child_session,
      child_id: "child-123",
      pane_state: %{
        stream_entries: [
          %{event_seq: 1, text: "first"},
          %{event_seq: 2, text: "second"}
        ]
      }
    }

    renderer = Map.fetch!(renderers, :child_session)

    assert %{
             id: "rendered-child-123",
             title: "Official child child-123",
             line: "child=child-123 entries=2"
           } = renderer.render(pane)
  end

  test "rejects renderer mappings from community-code plugins even with checksum approval" do
    plugin_path = tmp_plugin_dir!("community-renderer-mapping")
    manifest_path = Path.join(plugin_path, "capabilities.json")

    File.write!(
      manifest_path,
      Ourocode.Json.encode!(%{
        "capabilities" => ["pane_renderer"],
        "trust_tier" => "community_code",
        "renderer_mappings" => [
          %{"key" => "child_session", "module" => inspect(OfficialChildRenderer)}
        ]
      })
    )

    {:ok, expected_checksum} = Loader.checksum(plugin_path)

    approval = %{
      plugin_path: Path.expand(plugin_path),
      checksum: expected_checksum,
      trust_tier: "community_code",
      approved: true
    }

    assert {:error,
            %LoadError{
              reason: :untrusted_renderer_mapping_plugin,
              plugin_path: expanded_path,
              manifest_path: expanded_manifest_path
            }} =
             RendererMappingLoader.load_default(plugin_path,
               allowed_roots: [plugin_path],
               expected_checksum: expected_checksum,
               trusted_approvals: [approval]
             )

    assert_same_path(expanded_path, Path.expand(plugin_path))
    assert_same_path(expanded_manifest_path, manifest_path)
  end

  defp tmp_plugin_dir!(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-renderer-mapping-loader-test-#{name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)

    on_exit(fn ->
      File.rm_rf!(path)
    end)

    path
  end

  defp official_plugin_identity do
    %{
      plugin_id: "ouroboros-plugin",
      trust_classification: "official_trusted"
    }
  end

  defp signed_mapping(mapping_type, plugin, mapping, key_id, secret) do
    signature = MappingSignatureVerifier.sign(mapping_type, plugin, mapping, secret)

    Map.put(mapping, "signature", %{
      "algorithm" => "hmac-sha256",
      "key_id" => key_id,
      "value" => signature
    })
  end
end
