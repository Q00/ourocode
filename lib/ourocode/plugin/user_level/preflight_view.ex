defmodule Ourocode.Plugin.UserLevel.PreflightView do
  @moduledoc """
  JSON-safe projection of a `Ourocode.Plugin.UserLevel.PreflightResult` for
  TUIs, dashboards, and decision journals.

  The projection deliberately mirrors the field shape used by
  `Ourocode.Command.CapabilityPreflight.Projection` so any UI that already
  renders the slash-command preflight can render UserLevel plugin
  preflight without a separate code path.

  No execution, no trust mutation, no plugin-internal paths.
  """

  alias Ourocode.Plugin.UserLevel.Capability
  alias Ourocode.Plugin.UserLevel.Capability.Command, as: CommandCapability
  alias Ourocode.Plugin.UserLevel.PreflightResult

  @doc """
  Projects a `PreflightResult` into a JSON-safe map.
  """
  @spec project(PreflightResult.t()) :: map()
  def project(%PreflightResult{} = result) do
    %{
      kind: result.kind,
      task_input: result.task_input,
      reason: result.reason,
      plugin: plugin_view(result.plugin),
      command: command_view(result.command),
      args: result.args,
      trust: %{
        state: result.trust_state,
        remediation: result.remediation
      },
      side_effects: %{
        execution: execution_class(result.kind, result.command),
        discovery: :read_only,
        risk_class: result.risk_class,
        expected_artifacts: result.expected_artifacts,
        continuation_policy: result.continuation_policy
      },
      candidates: Enum.map(result.candidates, &plugin_view/1),
      match_explanation: result.match_explanation
    }
  end

  defp plugin_view(nil), do: nil

  defp plugin_view(%Capability{} = capability) do
    %{
      plugin_id: capability.plugin_id,
      plugin_name: capability.plugin_name,
      source: capability.source,
      version: capability.version,
      install_scope: capability.install_scope,
      trust_scope: capability.trust_scope,
      manifest_digest: capability.manifest_digest
    }
  end

  defp command_view(nil), do: nil

  defp command_view(%CommandCapability{} = command) do
    %{
      name: command.name,
      aliases: command.aliases,
      summary: command.summary,
      args: command.args,
      risk_class: command.risk_class,
      expected_artifacts: command.expected_artifacts,
      continuation_hint: command.continuation_hint
    }
  end

  defp execution_class(:unique_match, %CommandCapability{}), do: :pending_approval
  defp execution_class(_kind, _command), do: :blocked
end
