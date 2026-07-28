defmodule Ourocode.Plugin.ActionMappingLoaderTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ActionMappingLoader
  alias Ourocode.Plugin.LoadError
  alias Ourocode.Plugin.Loader
  alias Ourocode.Plugin.MappingSignatureVerifier

  defmodule OfficialSessionFocusAction do
    def execute(action_payload, context) do
      send(context.test_pid, {:official_action_called, action_payload, context})

      {:ok,
       %{
         focused?: true,
         child_id: action_payload.child_id,
         pane_state:
           Map.put(action_payload.pane_state, :focused_child_id, action_payload.child_id)
       }}
    end
  end

  test "loads signed official ouroboros-plugin action mappings into a runnable registry" do
    key_id = "official-action-key"
    secret = "official-action-secret"
    plugin_path = tmp_plugin_dir!("official-action-mapping")
    manifest_path = Path.join(plugin_path, "capabilities.json")
    plugin_identity = official_plugin_identity()

    action_mapping =
      signed_mapping(
        :action,
        plugin_identity,
        %{
          "key" => "session.focus",
          "module" => inspect(OfficialSessionFocusAction)
        },
        key_id,
        secret
      )

    File.write!(
      manifest_path,
      Ourocode.Json.encode!(%{
        "capabilities" => ["steering_action_mapping"],
        "plugin" => %{"id" => "ouroboros-plugin", "trust_tier" => "official"},
        "action_mappings" => [action_mapping]
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
              action_mappings: [
                mapping = %{
                  "key" => "session.focus",
                  "module" => module_name
                }
              ],
              actions: actions = %{{:session, :focus} => OfficialSessionFocusAction}
            }} =
             ActionMappingLoader.load_default(plugin_path,
               allowed_roots: [plugin_path],
               expected_checksum: expected_checksum,
               official_mapping_signing_keys: %{key_id => secret}
             )

    assert module_name == inspect(OfficialSessionFocusAction)

    assert %{
             "algorithm" => "hmac-sha256",
             "key_id" => ^key_id,
             "value" => signature
           } = mapping["signature"]

    assert is_binary(signature)

    action = Map.fetch!(actions, {:session, :focus})

    payload = %{
      child_id: "child-123",
      pane_state: %{open_child_ids: ["child-123"]}
    }

    assert {:ok,
            %{
              focused?: true,
              child_id: "child-123",
              pane_state: %{focused_child_id: "child-123"}
            }} = action.execute(payload, %{test_pid: self()})

    assert_receive {:official_action_called, ^payload, %{test_pid: test_pid}}
    assert test_pid == self()
  end

  test "rejects action mappings from community-code plugins even with checksum approval" do
    plugin_path = tmp_plugin_dir!("community-action-mapping")
    manifest_path = Path.join(plugin_path, "capabilities.json")

    File.write!(
      manifest_path,
      Ourocode.Json.encode!(%{
        "capabilities" => ["steering_action_mapping"],
        "trust_tier" => "community_code",
        "action_mappings" => [
          %{"key" => "session.focus", "module" => inspect(OfficialSessionFocusAction)}
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
              reason: :untrusted_action_mapping_plugin,
              plugin_path: expanded_path,
              manifest_path: actual_manifest_path
            }} =
             ActionMappingLoader.load_default(plugin_path,
               allowed_roots: [plugin_path],
               expected_checksum: expected_checksum,
               trusted_approvals: [approval]
             )

    assert_same_path(expanded_path, Path.expand(plugin_path))
    assert_same_path(actual_manifest_path, manifest_path)
  end

  defp tmp_plugin_dir!(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-action-mapping-loader-test-#{name}-#{System.unique_integer([:positive])}"
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

  defp assert_same_path(left, right) do
    if match?({:win32, _}, :os.type()) do
      assert path_key(left) == path_key(right)
    else
      assert left == right
    end
  end

  defp path_key(path) do
    path
    |> Path.expand()
    |> String.replace("\\", "/")
    |> String.downcase()
  end
end
