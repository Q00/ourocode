defmodule Ourocode.Runtime.Dispatcher.RouteResolutionUserLevelTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.Dispatcher.RouteResolution

  describe ":user_level_plugin route validation" do
    test "validate_decision/1 accepts a well-formed user_level_plugin decision" do
      decision = %{
        kind: :user_level_plugin,
        execution_route: :user_level_plugin,
        runtime_source: :ouroboros,
        transport: :auto,
        requires_command_syntax?: false,
        advanced_shortcut?: true,
        reason: :user_level_plugin_resolved,
        plugin_id: "superpowers"
      }

      assert :ok == RouteResolution.validate_decision(decision)
    end

    test "validate_decision/1 rejects a user_level_plugin decision that carries an adapter_route" do
      decision = %{
        kind: :user_level_plugin,
        execution_route: :user_level_plugin,
        runtime_source: :ouroboros,
        transport: :auto,
        requires_command_syntax?: false,
        advanced_shortcut?: true,
        reason: :user_level_plugin_resolved,
        plugin_id: "superpowers",
        adapter_route: :workflow
      }

      assert {:error, {:unexpected_adapter_route, :workflow}} =
               RouteResolution.validate_decision(decision)
    end
  end

  describe ":user_level_plugin adapter_keys" do
    test "scopes by plugin_id and falls back to generic key" do
      decision = %{
        execution_route: :user_level_plugin,
        runtime_source: :ouroboros,
        transport: :auto,
        plugin_id: "superpowers"
      }

      assert [{:user_level_plugin, "superpowers"}, :user_level_plugin] =
               RouteResolution.adapter_keys(decision)
    end

    test "falls back to :user_level_plugin when plugin_id is missing" do
      decision = %{
        execution_route: :user_level_plugin,
        runtime_source: :ouroboros,
        transport: :auto
      }

      assert [:user_level_plugin] = RouteResolution.adapter_keys(decision)
    end
  end
end
