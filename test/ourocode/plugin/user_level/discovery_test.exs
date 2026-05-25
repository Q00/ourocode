defmodule Ourocode.Plugin.UserLevel.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.UserLevel.Capability
  alias Ourocode.Plugin.UserLevel.Discovery

  defmodule StubAdapter do
    @behaviour Ourocode.Plugin.UserLevel.Discovery

    @impl true
    def discover(opts) do
      Map.new(opts) |> Map.get(:stub_result, {:ok, []})
    end
  end

  test "normalizes valid descriptors into Capability structs" do
    descriptors = [
      %{plugin_id: "superpowers", source: :ouroboros_cli, commands: [%{name: "list"}]},
      %{plugin_id: "other", source: :ouroboros_cli}
    ]

    assert {:ok, [a, b], []} =
             Discovery.run(StubAdapter, stub_result: {:ok, descriptors})

    assert %Capability{plugin_id: "superpowers", commands: [_command]} = a
    assert %Capability{plugin_id: "other", commands: []} = b
  end

  test "reports invalid descriptors without losing valid ones" do
    descriptors = [
      %{plugin_id: "good", source: :ouroboros_cli},
      %{source: :ouroboros_cli},
      %{plugin_id: "another_good", source: :ouroboros_cli}
    ]

    assert {:ok, capabilities, errors} =
             Discovery.run(StubAdapter, stub_result: {:ok, descriptors})

    assert Enum.map(capabilities, & &1.plugin_id) == ["good", "another_good"]
    assert [{:invalid_descriptor, {:invalid_capability_attrs, %{source: :ouroboros_cli}}}] = errors
  end

  test "propagates adapter errors unchanged" do
    assert {:error, :boom} ==
             Discovery.run(StubAdapter, stub_result: {:error, :boom})
  end
end
