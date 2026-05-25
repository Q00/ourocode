defmodule Ourocode.Plugin.UserLevel.Registry do
  @moduledoc """
  In-memory cache of installed Ouroboros UserLevel plugin capabilities.

  The registry is a small Agent that keeps the most recent discovery
  snapshot. Lookups are O(N) over a tiny N; the registry exists for
  freshness and identity stability, not for high-throughput access.

  Freshness:
    * `list/2` returns the cached snapshot, refreshing when it is older than
      `:max_age_ms` (default 60 s).
    * `refresh/2` is explicit (used by a `/plugins refresh` slash command
      and by the plugin config watcher signal handler).
    * Discovery failures degrade the snapshot to `:degraded` while keeping
      the last good capability list. Boot is never blocked.

  Identity stability:
    * Capabilities are deduplicated by
      `Ourocode.Plugin.UserLevel.Capability.identity/1`. A re-discovery
      without manifest changes returns the same struct instance, so
      downstream caches (preflight, panel, journal) do not churn.
  """

  use Agent

  alias Ourocode.Plugin.UserLevel.Capability
  alias Ourocode.Plugin.UserLevel.Discovery
  alias Ourocode.Plugin.UserLevel.Discovery.OuroborosCLI

  @default_ttl_ms 60_000
  @default_adapter OuroborosCLI

  @type status :: :ready | :degraded | :empty
  @type snapshot :: %{
          required(:status) => status(),
          required(:capabilities) => [Capability.t()],
          required(:errors) => [term()],
          required(:refreshed_at) => DateTime.t() | nil,
          required(:adapter) => module()
        }

  @doc """
  Starts the registry agent.

  Options:
    * `:name` — registered process name (defaults to `__MODULE__`).
    * `:adapter` — discovery adapter module (defaults to `OuroborosCLI`).
    * `:adapter_options` — passed verbatim to `adapter.discover/1`.
    * `:eager?` — when `true`, runs an initial discovery synchronously.
      Defaults to `false` so boot stays fast and offline-safe.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    adapter = Keyword.get(opts, :adapter, @default_adapter)
    adapter_options = Keyword.get(opts, :adapter_options, [])
    eager? = Keyword.get(opts, :eager?, false)

    initial = %{
      status: :empty,
      capabilities: [],
      errors: [],
      refreshed_at: nil,
      adapter: adapter,
      adapter_options: adapter_options
    }

    case Agent.start_link(fn -> initial end, name: name) do
      {:ok, pid} ->
        if eager?, do: _ = refresh(name)
        {:ok, pid}

      other ->
        other
    end
  end

  @doc """
  Returns the current snapshot, refreshing when older than `:max_age_ms`.

  Options:
    * `:max_age_ms` — TTL for the cached snapshot (defaults to
      `#{@default_ttl_ms}` ms). Pass `nil` to never auto-refresh — the
      cached snapshot is returned unchanged even when it is still empty,
      so callers can inspect the initial state without triggering
      discovery. To force discovery on first read, pass `max_age_ms: 0`
      or call `refresh/2` explicitly.
  """
  @spec list(GenServer.server(), keyword()) :: snapshot()
  def list(server \\ __MODULE__, opts \\ []) do
    max_age_ms = Keyword.get(opts, :max_age_ms, @default_ttl_ms)
    snapshot = Agent.get(server, & &1)

    if stale?(snapshot, max_age_ms) do
      refresh(server)
    else
      project(snapshot)
    end
  end

  @doc """
  Forces re-discovery through the configured adapter and updates the cache.

  Discovery failures preserve the previous capability list and surface as a
  `:degraded` snapshot with the error attached. Successful runs reset the
  error list and update `refreshed_at`.
  """
  @spec refresh(GenServer.server(), keyword()) :: snapshot()
  def refresh(server \\ __MODULE__, opts \\ []) do
    Agent.get_and_update(server, fn current ->
      adapter = Keyword.get(opts, :adapter, current.adapter)
      adapter_options = Keyword.get(opts, :adapter_options, current.adapter_options)

      next = run_discovery(current, adapter, adapter_options)

      new_state =
        current
        |> Map.put(:adapter, adapter)
        |> Map.put(:adapter_options, adapter_options)
        |> Map.merge(next)

      {project(new_state), new_state}
    end)
  end

  @doc """
  Looks up a capability by plugin id from the cached snapshot.

  Does not trigger discovery. Callers that need freshness should call
  `list/2` first.
  """
  @spec fetch(GenServer.server(), String.t()) :: {:ok, Capability.t()} | :error
  def fetch(server \\ __MODULE__, plugin_id) when is_binary(plugin_id) do
    snapshot = Agent.get(server, & &1)

    case Enum.find(snapshot.capabilities, &(&1.plugin_id == plugin_id)) do
      nil -> :error
      capability -> {:ok, capability}
    end
  end

  # `max_age_ms: nil` takes precedence over an empty cache so callers can
  # inspect the initial state without triggering discovery.
  defp stale?(_snapshot, nil), do: false
  defp stale?(%{refreshed_at: nil}, _max_age_ms), do: true

  defp stale?(%{refreshed_at: refreshed_at}, max_age_ms) do
    DateTime.diff(DateTime.utc_now(), refreshed_at, :millisecond) > max_age_ms
  end

  defp run_discovery(current, adapter, adapter_options) do
    case Discovery.run(adapter, adapter_options) do
      {:ok, capabilities, descriptor_errors} ->
        merged = preserve_identity(current.capabilities, capabilities)

        %{
          status: status_for(merged, descriptor_errors),
          capabilities: merged,
          errors: descriptor_errors,
          refreshed_at: DateTime.utc_now(),
          adapter: adapter
        }

      {:error, reason} ->
        %{
          status: :degraded,
          capabilities: current.capabilities,
          errors: [{:discovery_failed, reason} | current.errors],
          refreshed_at: DateTime.utc_now(),
          adapter: adapter
        }
    end
  end

  defp status_for([], []), do: :empty
  defp status_for(_capabilities, _errors), do: :ready

  defp preserve_identity(previous, fresh) do
    index = Map.new(previous, fn cap -> {Capability.identity(cap), cap} end)

    Enum.map(fresh, fn cap ->
      Map.get(index, Capability.identity(cap), cap)
    end)
  end

  defp project(snapshot) do
    Map.take(snapshot, [:status, :capabilities, :errors, :refreshed_at, :adapter])
  end
end
