defmodule Ourocode.Plugin.UserLevel.RegistryEntry do
  @moduledoc """
  Projects `Ourocode.Plugin.UserLevel.Capability` into the normalized
  command_entry shape consumed by `Ourocode.Command.Registry`.

  This bridge lets the existing slash command surface and
  `Ourocode.Command.CapabilityPreflight` see UserLevel plugins as first-class
  registry entries without duplicating projection logic. The metadata shape
  intentionally mirrors `Ourocode.Command.Registry.PluginSurfaceEntry` so
  `CapabilityPreflight.Trust` and `CapabilityPreflight.Projection` work
  unchanged.

  Trust defaults are conservative: the registry assumes `requires_explicit_approval`
  unless the discovered capability declares trust scopes. Granting trust
  remains an Ouroboros responsibility; `ourocode` only surfaces what was
  reported.
  """

  alias Ourocode.Plugin.UserLevel.Capability
  alias Ourocode.Plugin.UserLevel.Capability.Command, as: CommandCapability

  @doc """
  Returns a list of registry-shaped maps suitable for
  `Ourocode.Command.Registry.merge_normalized_entries/2`.

  One entry per command capability is produced.
  """
  @spec entries([Capability.t()] | Capability.t()) :: [map()]
  def entries(capabilities) when is_list(capabilities) do
    Enum.flat_map(capabilities, &entries/1)
  end

  def entries(%Capability{} = capability) do
    Enum.map(capability.commands, &entry(capability, &1))
  end

  defp entry(%Capability{} = capability, %CommandCapability{} = command) do
    slash = "/" <> capability.plugin_id <> " " <> command.name

    aliases =
      Enum.map(command.aliases, fn alias_name ->
        "/" <> capability.plugin_id <> " " <> alias_name
      end)

    args =
      Enum.map(command.args, fn arg ->
        %{
          name: Map.get(arg, :name, ""),
          required?: Map.get(arg, :required?, false),
          description: Map.get(arg, :description, "")
        }
      end)

    %{
      id: "user_level_plugin:#{capability.plugin_id}:#{command.name}",
      name: "#{capability.plugin_id} #{command.name}",
      slash: slash,
      source: :plugin,
      source_id: capability.plugin_id,
      source_attribution: source_attribution(capability),
      type: :slash_command,
      category: :plugins,
      summary: command.summary || "",
      aliases: aliases,
      args: args,
      availability: :available,
      runnable?: true,
      run_spec: %{
        kind: :user_level_plugin_command,
        plugin_id: capability.plugin_id,
        command: command.name,
        risk_class: command.risk_class,
        expected_artifacts: command.expected_artifacts,
        continuation_hint: command.continuation_hint
      },
      metadata: %{
        plugin_id: capability.plugin_id,
        plugin_source: capability.source,
        plugin_surface: :user_level,
        command_namespace: capability.plugin_id,
        namespace_owner: :ouroboros,
        trust_policy: trust_policy(capability),
        trust_evaluation: trust_evaluation(capability),
        trust_policy_state: nil,
        expected_outputs: command.expected_artifacts,
        risk_class: command.risk_class,
        capability_version: capability.version,
        manifest_digest: capability.manifest_digest
      }
    }
  end

  defp source_attribution(%Capability{} = capability) do
    %{
      source: :plugin,
      source_id: capability.plugin_id,
      plugin_id: capability.plugin_id,
      plugin_source: capability.source,
      plugin_surface: :user_level,
      command_namespace: capability.plugin_id,
      namespace_owner: :ouroboros,
      capability_version: capability.version,
      manifest_digest: capability.manifest_digest
    }
  end

  defp trust_policy(%Capability{trust_scope: scopes}) when scopes != [] do
    %{
      "tier" => "user_level",
      "requires_explicit_approval" => false,
      "trust_scopes" => scopes
    }
  end

  defp trust_policy(_capability) do
    %{
      "tier" => "user_level",
      "requires_explicit_approval" => true
    }
  end

  defp trust_evaluation(%Capability{trust_scope: scopes}) do
    %{
      "trusted" => scopes != [],
      "trust_scopes" => scopes
    }
  end
end
