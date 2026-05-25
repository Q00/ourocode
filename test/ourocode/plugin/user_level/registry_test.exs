defmodule Ourocode.Plugin.UserLevel.RegistryTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.UserLevel.Capability
  alias Ourocode.Plugin.UserLevel.Registry

  defmodule StubAdapter do
    @behaviour Ourocode.Plugin.UserLevel.Discovery

    @impl true
    def discover(opts) do
      Map.new(opts) |> Map.get(:stub_result, {:ok, []})
    end
  end

  setup do
    name = :"user_level_registry_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Registry.start_link(name: name, adapter: StubAdapter)
    %{registry: name}
  end

  test "starts in :empty status with no capabilities", %{registry: registry} do
    snapshot = Registry.list(registry, max_age_ms: nil)
    assert snapshot.status == :empty
    assert snapshot.capabilities == []
    assert snapshot.refreshed_at == nil
  end

  test "refresh/2 with successful discovery returns :ready snapshot", %{registry: registry} do
    descriptors = [%{plugin_id: "superpowers", source: :fixture, version: "1.0.0"}]

    snapshot =
      Registry.refresh(registry, adapter_options: [stub_result: {:ok, descriptors}])

    assert snapshot.status == :ready
    assert [%Capability{plugin_id: "superpowers"}] = snapshot.capabilities
    assert %DateTime{} = snapshot.refreshed_at
    assert snapshot.errors == []
  end

  test "refresh/2 surface adapter errors as :degraded snapshot", %{registry: registry} do
    snapshot =
      Registry.refresh(registry, adapter_options: [stub_result: {:error, :boom}])

    assert snapshot.status == :degraded
    assert snapshot.capabilities == []
    assert [{:discovery_failed, :boom}] = snapshot.errors
    assert %DateTime{} = snapshot.refreshed_at
  end

  test "refresh/2 preserves last good capabilities on subsequent failure", %{registry: registry} do
    descriptors = [%{plugin_id: "superpowers", source: :fixture}]

    Registry.refresh(registry, adapter_options: [stub_result: {:ok, descriptors}])

    after_failure =
      Registry.refresh(registry, adapter_options: [stub_result: {:error, :network}])

    assert after_failure.status == :degraded
    assert [%Capability{plugin_id: "superpowers"}] = after_failure.capabilities
    assert [{:discovery_failed, :network} | _] = after_failure.errors
  end

  test "identity stability: same struct instance is returned across refreshes", %{
    registry: registry
  } do
    descriptors = [
      %{
        plugin_id: "superpowers",
        source: :fixture,
        version: "0.4.2",
        manifest_digest: "sha256:abc"
      }
    ]

    %{capabilities: [first]} =
      Registry.refresh(registry, adapter_options: [stub_result: {:ok, descriptors}])

    %{capabilities: [second]} =
      Registry.refresh(registry, adapter_options: [stub_result: {:ok, descriptors}])

    # Same identity -> reused struct
    assert first == second
    assert Capability.identity(first) == Capability.identity(second)
  end

  test "list/2 with TTL=0 triggers a refresh using the cached adapter options",
       %{registry: registry} do
    descriptors = [%{plugin_id: "x", source: :fixture}]

    # Seed the adapter options once via an explicit refresh.
    Registry.refresh(registry, adapter_options: [stub_result: {:ok, descriptors}])

    # max_age_ms: 0 forces stale; list/2 must re-run discovery with the
    # adapter options it was configured with.
    snapshot = Registry.list(registry, max_age_ms: 0)
    assert [%Capability{plugin_id: "x"}] = snapshot.capabilities

    # max_age_ms: nil returns the cached snapshot unchanged.
    cached = Registry.list(registry, max_age_ms: nil)
    assert cached.refreshed_at == snapshot.refreshed_at
  end

  test "fetch/2 returns capability by plugin_id from cached snapshot", %{registry: registry} do
    descriptors = [
      %{plugin_id: "superpowers", source: :fixture},
      %{plugin_id: "other", source: :fixture}
    ]

    Registry.refresh(registry, adapter_options: [stub_result: {:ok, descriptors}])

    assert {:ok, %Capability{plugin_id: "superpowers"}} =
             Registry.fetch(registry, "superpowers")

    assert :error == Registry.fetch(registry, "unknown")
  end
end
