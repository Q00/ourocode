defmodule Ourocode.Plugin.UserLevel.Resolver do
  @moduledoc """
  Pure resolver from `ooo <plugin> <command> [args ...]`-shaped input to a
  `Ourocode.Plugin.UserLevel.PreflightResult`.

  The resolver is intentionally narrow:

    * Direct command form only — the first token must be `ooo` or
      `ouroboros`. Free-form natural language is deferred until the exact
      path is stable.
    * Exact match only on plugin id and command name/alias. Fuzzy matching
      is explicitly out of scope; ambiguity surfaces as `:ambiguous` with
      candidate plugins rather than as a guess.
    * No execution, no trust mutation. The resolver only describes what a
      dispatch step *would* do.

  Trust mapping:

    * A capability whose `trust_scope` is non-empty is considered
      `:allowed`. The Ouroboros plugin list is the source of truth — if
      Ouroboros declares scopes, the user has granted them.
    * A capability whose `trust_scope` is empty surfaces as `:missing`
      with a remediation string suggesting `ouroboros plugin trust ...`.
      Granting trust remains an Ouroboros responsibility.
  """

  alias Ourocode.Plugin.UserLevel.Capability
  alias Ourocode.Plugin.UserLevel.Capability.Command, as: CommandCapability
  alias Ourocode.Plugin.UserLevel.PreflightResult

  @ooo_prefixes ["ooo", "ouroboros"]

  @doc """
  Resolves `task_input` against the given capability list.

  Returns a `PreflightResult`. The resolver never raises and never mutates
  capabilities; callers can pass a registry snapshot directly.
  """
  @spec resolve(String.t(), [Capability.t()]) :: PreflightResult.t()
  def resolve(task_input, capabilities) when is_binary(task_input) and is_list(capabilities) do
    trimmed = String.trim(task_input)

    case tokenize(trimmed) do
      [prefix, plugin_token | rest] ->
        if ooo_prefix?(prefix) do
          resolve_plugin(trimmed, plugin_token, rest, capabilities)
        else
          not_applicable(trimmed)
        end

      [prefix] ->
        if ooo_prefix?(prefix) do
          unknown(trimmed, :missing_plugin_token)
        else
          not_applicable(trimmed)
        end

      [] ->
        not_applicable(trimmed)
    end
  end

  def resolve(_task_input, _capabilities), do: not_applicable("")

  defp resolve_plugin(input, plugin_token, rest, capabilities) do
    normalized = String.downcase(plugin_token)

    case Enum.filter(capabilities, &(String.downcase(&1.plugin_id) == normalized)) do
      [] ->
        unknown(input, :unknown_plugin)

      [capability] ->
        resolve_command(input, capability, rest)

      [_ | _] = matches ->
        ambiguous(input, matches)
    end
  end

  defp resolve_command(input, capability, []) do
    %PreflightResult{
      kind: :unknown,
      task_input: input,
      plugin: capability,
      command: nil,
      args: [],
      trust_state: trust_state(capability),
      remediation: remediation_for(capability),
      risk_class: :unknown,
      expected_artifacts: [],
      continuation_policy: :none,
      candidates: [],
      match_explanation: %{matched_by: nil, confidence: :none},
      reason: :missing_command_token
    }
  end

  defp resolve_command(input, capability, [command_token | args]) do
    normalized = String.downcase(command_token)

    case find_command_ci(capability, normalized) do
      nil ->
        %PreflightResult{
          kind: :unknown,
          task_input: input,
          plugin: capability,
          command: nil,
          args: args,
          trust_state: trust_state(capability),
          remediation: remediation_for(capability),
          risk_class: :unknown,
          expected_artifacts: [],
          continuation_policy: :none,
          candidates: [],
          match_explanation: %{matched_by: nil, confidence: :none},
          reason: :unknown_command
        }

      %CommandCapability{} = command ->
        unique_match(input, capability, command, normalized, args)
    end
  end

  defp find_command_ci(%Capability{commands: commands}, normalized_token) do
    Enum.find(commands, fn cmd ->
      String.downcase(cmd.name) == normalized_token or
        normalized_token in Enum.map(cmd.aliases, &String.downcase/1)
    end)
  end

  defp unique_match(input, capability, command, normalized_token, args) do
    confidence =
      cond do
        String.downcase(command.name) == normalized_token -> :exact
        normalized_token in Enum.map(command.aliases, &String.downcase/1) -> :alias
        true -> :none
      end

    matched_by =
      cond do
        String.downcase(command.name) == normalized_token -> :canonical
        normalized_token in Enum.map(command.aliases, &String.downcase/1) -> :alias
        true -> nil
      end

    %PreflightResult{
      kind: :unique_match,
      task_input: input,
      plugin: capability,
      command: command,
      args: args,
      trust_state: trust_state(capability),
      remediation: remediation_for(capability),
      risk_class: command.risk_class,
      expected_artifacts: command.expected_artifacts,
      continuation_policy: continuation_policy_for(command),
      candidates: [],
      match_explanation: %{matched_by: matched_by, confidence: confidence},
      reason: nil
    }
  end

  defp ambiguous(input, candidates) do
    %PreflightResult{
      kind: :ambiguous,
      task_input: input,
      plugin: nil,
      command: nil,
      args: [],
      trust_state: :unknown,
      remediation: nil,
      risk_class: :unknown,
      expected_artifacts: [],
      continuation_policy: :none,
      candidates: candidates,
      match_explanation: %{matched_by: nil, confidence: :none},
      reason: :duplicate_plugin_ids
    }
  end

  defp unknown(input, reason) do
    %PreflightResult{
      kind: :unknown,
      task_input: input,
      plugin: nil,
      command: nil,
      args: [],
      trust_state: :unknown,
      remediation: nil,
      risk_class: :unknown,
      expected_artifacts: [],
      continuation_policy: :none,
      candidates: [],
      match_explanation: %{matched_by: nil, confidence: :none},
      reason: reason
    }
  end

  defp not_applicable(input) do
    %PreflightResult{
      kind: :not_applicable,
      task_input: input,
      plugin: nil,
      command: nil,
      args: [],
      trust_state: :unknown,
      remediation: nil,
      risk_class: :unknown,
      expected_artifacts: [],
      continuation_policy: :none,
      candidates: [],
      match_explanation: %{matched_by: nil, confidence: :none},
      reason: :not_user_level_plugin_input
    }
  end

  @doc """
  Convenience predicate for routing layers: returns `true` when `task_input`
  syntactically targets a UserLevel plugin known to `capabilities`.

  Does not evaluate trust or command validity; that is the job of `resolve/2`.
  Callers can use this to decide whether to swap the routing decision before
  invoking the dispatcher.
  """
  @spec applies_to?(String.t(), [Capability.t()]) :: boolean()
  def applies_to?(task_input, capabilities)
      when is_binary(task_input) and is_list(capabilities) do
    case tokenize(String.trim(task_input)) do
      [prefix, plugin_token | _rest] ->
        if ooo_prefix?(prefix) do
          normalized = String.downcase(plugin_token)
          Enum.any?(capabilities, &(String.downcase(&1.plugin_id) == normalized))
        else
          false
        end

      _other ->
        false
    end
  end

  def applies_to?(_task_input, _capabilities), do: false

  defp tokenize(""), do: []
  defp tokenize(input), do: String.split(input, ~r/\s+/u, trim: true)

  defp ooo_prefix?(prefix), do: String.downcase(prefix) in @ooo_prefixes

  defp trust_state(%Capability{trust_scope: scopes}) when scopes != [], do: :allowed
  defp trust_state(%Capability{}), do: :missing

  defp remediation_for(%Capability{trust_scope: scopes, plugin_id: id}) when scopes == [] do
    "ouroboros plugin trust #{id} --scope <required-scope>"
  end

  defp remediation_for(_capability), do: nil

  defp continuation_policy_for(%CommandCapability{continuation_hint: :auto_run_when_requested}),
    do: :auto_when_requested

  defp continuation_policy_for(%CommandCapability{continuation_hint: :suggest_run}), do: :suggest
  defp continuation_policy_for(%CommandCapability{}), do: :none
end
