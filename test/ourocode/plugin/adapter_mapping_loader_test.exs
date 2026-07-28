defmodule Ourocode.Plugin.AdapterMappingLoaderTest do
  use ExUnit.Case, async: true

  import Ourocode.Test.PathAssertions, only: [assert_same_path: 2]

  alias Ourocode.Plugin.AdapterMappingLoader
  alias Ourocode.Plugin.LoadError
  alias Ourocode.Plugin.Loader
  alias Ourocode.Plugin.MappingSignatureVerifier
  alias Ourocode.Runtime.Dispatcher
  alias Ourocode.TaskRequest

  defmodule OfficialMappedAdapter do
    @behaviour Ourocode.Runtime.Adapter

    @impl true
    def execute(task_request, context) do
      send(context.test_pid, {:official_mapped_adapter_called, task_request, context})
      {:ok, {:official_mapping, task_request.id}}
    end
  end

  test "loads signed official ouroboros-plugin adapter mappings into a runnable registry" do
    key_id = "official-adapter-key"
    secret = "official-adapter-secret"
    plugin_path = tmp_plugin_dir!("official-adapter-mapping")
    manifest_path = Path.join(plugin_path, "capabilities.json")
    plugin_identity = official_plugin_identity()

    adapter_mapping =
      signed_mapping(
        :adapter,
        plugin_identity,
        %{
          "key" => "ouroboros_workflow.interview",
          "module" => inspect(OfficialMappedAdapter)
        },
        key_id,
        secret
      )

    File.write!(
      manifest_path,
      Ourocode.Json.encode!(%{
        "capabilities" => ["adapter_mapping"],
        "plugin" => %{"id" => "ouroboros-plugin", "trust_tier" => "official"},
        "adapter_mappings" => [adapter_mapping]
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
              adapter_mappings: [
                mapping = %{
                  "key" => "ouroboros_workflow.interview",
                  "module" => module_name
                }
              ],
              adapters: adapters = %{{:ouroboros_workflow, :interview} => OfficialMappedAdapter}
            }} =
             AdapterMappingLoader.load_default(plugin_path,
               allowed_roots: [plugin_path],
               expected_checksum: expected_checksum,
               official_mapping_signing_keys: %{key_id => secret}
             )

    assert module_name == inspect(OfficialMappedAdapter)

    assert %{
             "algorithm" => "hmac-sha256",
             "key_id" => ^key_id,
             "value" => signature
           } = mapping["signature"]

    assert is_binary(signature)

    {:ok, task_request} =
      TaskRequest.parse("ooo interview clarify adapter mappings", id: "mapped-task")

    assert {:ok, {:official_mapping, "mapped-task"}} =
             Dispatcher.dispatch(task_request,
               adapters: adapters,
               context: %{test_pid: self()}
             )

    assert_receive {:official_mapped_adapter_called, ^task_request, context}
    assert context.adapter_route == :interview
    assert context.runtime_source == :ouroboros
  end

  test "rejects adapter mappings from community-code plugins even with checksum approval" do
    plugin_path = tmp_plugin_dir!("community-adapter-mapping")
    manifest_path = Path.join(plugin_path, "capabilities.json")

    File.write!(
      manifest_path,
      Ourocode.Json.encode!(%{
        "capabilities" => ["adapter_mapping"],
        "trust_tier" => "community_code",
        "adapter_mappings" => [
          %{"key" => "runtime", "module" => inspect(OfficialMappedAdapter)}
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
              reason: :untrusted_adapter_mapping_plugin,
              plugin_path: expanded_path,
              manifest_path: actual_manifest_path
            }} =
             AdapterMappingLoader.load_default(plugin_path,
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
        "ourocode-adapter-mapping-loader-test-#{name}-#{System.unique_integer([:positive])}"
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
