defmodule Ourocode.Plugin.UserLevel.Discovery do
  @moduledoc """
  Behaviour for discovering installed Ouroboros UserLevel plugins.

  Discovery adapters are read-only: they ask Ouroboros which plugins are
  installed and return one descriptor per plugin. They must never install,
  trust, escalate, or execute plugin code. Caching, freshness, and identity
  stability live in `Ourocode.Plugin.UserLevel.Registry`, not in the adapter.

  The behaviour is transport-neutral: a CLI adapter and an MCP adapter can
  both satisfy it, and the registry treats them interchangeably.
  """

  alias Ourocode.Plugin.UserLevel.Capability

  @type raw_descriptor :: map()
  @type discovery_options :: keyword() | map()
  @type discovery_result ::
          {:ok, [raw_descriptor()]}
          | {:error, atom() | {atom(), term()}}

  @callback discover(discovery_options()) :: discovery_result()

  @doc """
  Runs an adapter and normalizes raw descriptors into `Capability` structs.

  Per-descriptor validation failures are reported separately so the registry
  can keep the good capabilities while logging the bad ones. Adapter-level
  failures bubble up unchanged.
  """
  @spec run(module(), discovery_options()) ::
          {:ok, [Capability.t()], [{:invalid_descriptor, term()}]}
          | {:error, term()}
  def run(adapter, opts \\ []) when is_atom(adapter) do
    with {:ok, descriptors} <- adapter.discover(opts) do
      {capabilities, errors} =
        Enum.reduce(descriptors, {[], []}, fn descriptor, {ok_acc, err_acc} ->
          case Capability.new(descriptor) do
            {:ok, capability} ->
              {[capability | ok_acc], err_acc}

            {:error, reason} ->
              {ok_acc, [{:invalid_descriptor, {reason, descriptor}} | err_acc]}
          end
        end)

      {:ok, Enum.reverse(capabilities), Enum.reverse(errors)}
    end
  end
end
