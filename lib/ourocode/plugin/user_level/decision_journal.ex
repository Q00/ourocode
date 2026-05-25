defmodule Ourocode.Plugin.UserLevel.DecisionJournal do
  @moduledoc """
  Appends one structured event per UserLevel plugin decision phase into the
  existing `Ourocode.Journal.Writer`.

  Four phases are recorded so the audit trail can answer "why did ourocode
  pick this plugin, did it run, what did it produce, did the user continue":

    * `:user_level_preflight` — the PreflightResult that drove dispatch.
    * `:user_level_dispatch` — the invocation envelope (argv, status,
      blocked reason or execution status).
    * `:user_level_artifact` — one event per produced artifact (so the
      audit can reconstruct which files attached to which task).
    * `:user_level_continuation` — the continuation decision (none /
      suggest / auto_run, with seed path and reason).

  Events are written via `Journal.Writer.append/2` so they share the same
  durable format and sequencing rules as the rest of the runtime journal.
  The module is a thin shape-builder; it never decides what to log on its
  own.
  """

  alias Ourocode.Journal.Writer
  alias Ourocode.Plugin.UserLevel.ArtifactWatcher
  alias Ourocode.Plugin.UserLevel.Capability
  alias Ourocode.Plugin.UserLevel.PreflightResult
  alias Ourocode.Plugin.UserLevel.PreflightView

  @type writer :: (map() -> :ok | {:error, term()})

  @doc """
  Logs a preflight event.

  `journal` may be a `Path.t()` (passed straight to `Journal.Writer.append/2`)
  or a 1-arity function for tests (`fn event -> :ok end`).
  """
  @spec log_preflight(any(), String.t(), PreflightResult.t()) :: :ok | {:error, term()}
  def log_preflight(journal, task_request_id, %PreflightResult{} = preflight) do
    append(journal, base_event(:user_level_preflight, task_request_id, %{
      preflight: PreflightView.project(preflight)
    }))
  end

  @doc """
  Logs a dispatch envelope event.
  """
  @spec log_dispatch(any(), String.t(), map()) :: :ok | {:error, term()}
  def log_dispatch(journal, task_request_id, invocation) when is_map(invocation) do
    append(journal, base_event(:user_level_dispatch, task_request_id, %{
      status: Map.get(invocation, :status),
      command: Map.get(invocation, :command),
      argv: Map.get(invocation, :argv),
      blocked_reason: Map.get(invocation, :blocked_reason),
      execution_status: get_in(invocation, [:execution, :status]),
      plugin_id: get_in(invocation, [:preflight, Access.key(:plugin), Access.key(:plugin_id)])
    }))
  end

  @doc """
  Logs one event per produced artifact.

  No-op when the artifact list is empty.
  """
  @spec log_artifacts(any(), String.t(), [ArtifactWatcher.artifact()]) ::
          :ok | {:error, term()}
  def log_artifacts(_journal, _task_request_id, []), do: :ok

  def log_artifacts(journal, task_request_id, artifacts) when is_list(artifacts) do
    Enum.reduce_while(artifacts, :ok, fn artifact, _acc ->
      event = base_event(:user_level_artifact, task_request_id, %{
        artifact_kind: Map.get(artifact, :kind),
        path: Map.get(artifact, :path),
        glob: Map.get(artifact, :glob),
        size: Map.get(artifact, :size),
        digest: Map.get(artifact, :digest),
        generated_at: maybe_iso(Map.get(artifact, :generated_at))
      })

      case append(journal, event) do
        :ok -> {:cont, :ok}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
  end

  @doc """
  Logs the continuation decision (none / suggest / auto_run).
  """
  @spec log_continuation(any(), String.t(), map()) :: :ok | {:error, term()}
  def log_continuation(journal, task_request_id, decision) when is_map(decision) do
    append(journal, base_event(:user_level_continuation, task_request_id, %{
      action: Map.get(decision, :action),
      seed_path: Map.get(decision, :seed_path),
      command_template: Map.get(decision, :command_template),
      reason: Map.get(decision, :reason)
    }))
  end

  defp base_event(type, task_request_id, payload) do
    %{
      "event_type" => Atom.to_string(type),
      "task_request_id" => to_string(task_request_id),
      "recorded_at_ms" => System.system_time(:millisecond),
      "payload" => stringify(payload)
    }
  end

  defp append(journal, event) when is_function(journal, 1), do: journal.(event)

  defp append(journal, event) when is_binary(journal) do
    Writer.append(journal, event)
  end

  defp append(_journal, _event), do: {:error, :invalid_journal_target}

  defp maybe_iso(nil), do: nil
  defp maybe_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp maybe_iso(other), do: other

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_value(v)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp stringify_value(%Capability{} = cap), do: stringify(Map.from_struct(cap))
  defp stringify_value(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp stringify_value(value), do: value
end
