defmodule Ourocode.Plugin.UserLevel.Continuation do
  @moduledoc """
  Decides whether a UserLevel plugin run should be followed up with an
  Ouroboros workflow step (`ooo run seed_path=...`), and whether to auto-run
  that follow-up or merely suggest it.

  Policy is intentionally conservative:

    * `:read_only` commands → no continuation.
    * `:handoff_producing` commands with a detected seed artifact → suggest
      a continuation. Auto-run only when the original prompt contains an
      explicit opt-in phrase such as "then run the generated handoff" (en)
      or "이어서 실행" (ko).
    * `:destructive` commands → never auto-continue. The continuation card
      may be suggested but always requires explicit approval.

  Auto-run intent detection is a small allow-list of substrings. Free-form
  natural-language detection is out of scope.
  """

  alias Ourocode.Plugin.UserLevel.ArtifactWatcher
  alias Ourocode.Plugin.UserLevel.Capability.Command, as: CommandCapability
  alias Ourocode.Plugin.UserLevel.PreflightResult

  @type decision :: %{
          required(:action) => :none | :suggest | :auto_run,
          required(:seed_path) => String.t() | nil,
          required(:command_template) => String.t() | nil,
          required(:reason) => atom()
        }

  # Explicit opt-in phrases. Keep this list short and review-friendly.
  @auto_run_intents [
    "then run the generated handoff",
    "then run the seed",
    "and run the seed",
    "이어서 실행",
    "이후 실행"
  ]

  @doc """
  Decides the continuation action for a finished run.

  Inputs:

    * `preflight` — the original PreflightResult (provides risk class +
      continuation policy + the user's task_input).
    * `artifacts` — list of artifacts produced by the run (typically the
      output of `ArtifactWatcher.scan/3`).
  """
  @spec decide(PreflightResult.t(), [ArtifactWatcher.artifact()]) :: decision()
  def decide(%PreflightResult{} = preflight, artifacts) when is_list(artifacts) do
    seed = Enum.find(artifacts, &(&1.kind == :seed))

    case continuation_action(preflight, seed) do
      :auto_run ->
        %{
          action: :auto_run,
          seed_path: seed && seed.path,
          command_template: command_template(seed),
          reason: :auto_run_requested
        }

      :suggest ->
        %{
          action: :suggest,
          seed_path: seed && seed.path,
          command_template: command_template(seed),
          reason: suggest_reason(preflight)
        }

      :none ->
        %{
          action: :none,
          seed_path: nil,
          command_template: nil,
          reason: none_reason(preflight, seed)
        }
    end
  end

  defp continuation_action(%PreflightResult{kind: :unique_match} = preflight, seed) do
    cond do
      preflight.risk_class == :read_only ->
        :none

      preflight.risk_class == :destructive ->
        if seed, do: :suggest, else: :none

      seed == nil ->
        :none

      auto_run_requested?(preflight.task_input) and
          allows_auto_run?(preflight.command) ->
        :auto_run

      true ->
        :suggest
    end
  end

  defp continuation_action(_preflight, _seed), do: :none

  defp allows_auto_run?(%CommandCapability{continuation_hint: hint}) do
    hint in [:auto_run_when_requested, :suggest_run]
  end

  defp allows_auto_run?(_command), do: false

  @doc """
  Returns `true` when the user's input contains an explicit opt-in phrase
  for auto-running the generated continuation. Public so callers can preview
  the intent without re-running the decision.
  """
  @spec auto_run_requested?(String.t()) :: boolean()
  def auto_run_requested?(task_input) when is_binary(task_input) do
    normalized = String.downcase(task_input)
    Enum.any?(@auto_run_intents, &String.contains?(normalized, &1))
  end

  def auto_run_requested?(_other), do: false

  defp command_template(nil), do: nil
  defp command_template(%{path: path}), do: "ooo run seed_path=#{path}"

  defp suggest_reason(%PreflightResult{risk_class: :destructive}),
    do: :destructive_requires_explicit_approval

  defp suggest_reason(_preflight), do: :user_confirmation_required

  defp none_reason(%PreflightResult{risk_class: :read_only}, _seed), do: :read_only_command

  defp none_reason(_preflight, nil), do: :no_continuation_artifact

  defp none_reason(_preflight, _seed), do: :no_continuation_policy
end
