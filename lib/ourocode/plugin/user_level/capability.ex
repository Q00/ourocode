defmodule Ourocode.Plugin.UserLevel.Capability do
  @moduledoc """
  Normalized identity and command surface for one installed Ouroboros
  UserLevel plugin.

  `ourocode` only consumes this struct. Ouroboros remains the source of truth
  for installation, trust, and execution; this module describes what was
  discovered so the runtime can route, preflight, and render UserLevel plugin
  commands without guessing.
  """

  alias Ourocode.Plugin.UserLevel.Capability.Command, as: CommandCapability

  @enforce_keys [:plugin_id, :source]
  defstruct plugin_id: nil,
            plugin_name: nil,
            source: nil,
            version: nil,
            install_scope: :unknown,
            trust_scope: [],
            manifest_digest: nil,
            commands: [],
            discovered_at: nil,
            resolution_origin: %{}

  @type install_scope :: :user | :workspace | :unknown
  @type trust_scope :: String.t()
  @type source :: :ouroboros_cli | :ouroboros_mcp | :fixture

  @type t :: %__MODULE__{
          plugin_id: String.t(),
          plugin_name: String.t() | nil,
          source: source(),
          version: String.t() | nil,
          install_scope: install_scope(),
          trust_scope: [trust_scope()],
          manifest_digest: String.t() | nil,
          commands: [CommandCapability.t()],
          discovered_at: DateTime.t() | nil,
          resolution_origin: map()
        }

  @valid_sources [:ouroboros_cli, :ouroboros_mcp, :fixture]
  @valid_scopes [:user, :workspace, :unknown]

  @doc """
  Builds a `Capability` from a normalized descriptor produced by a discovery
  adapter.

  Required fields:
    * `plugin_id` (non-empty string)
    * `source` (atom in `#{inspect(@valid_sources)}`)

  Invalid command descriptors are dropped silently so a single bad command
  does not lose the whole plugin. Top-level shape violations return
  `{:error, :invalid_capability_attrs}`.
  """
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_capability_attrs}
  def new(%{plugin_id: id, source: source} = attrs)
      when is_binary(id) and id != "" and source in @valid_sources do
    commands =
      attrs
      |> Map.get(:commands, [])
      |> List.wrap()
      |> Enum.flat_map(fn descriptor ->
        case CommandCapability.new(descriptor) do
          {:ok, command} -> [command]
          {:error, _reason} -> []
        end
      end)

    install_scope = Map.get(attrs, :install_scope, :unknown)
    install_scope = if install_scope in @valid_scopes, do: install_scope, else: :unknown

    {:ok,
     %__MODULE__{
       plugin_id: id,
       plugin_name: Map.get(attrs, :plugin_name) || id,
       source: source,
       version: Map.get(attrs, :version),
       install_scope: install_scope,
       trust_scope: normalize_scopes(Map.get(attrs, :trust_scope, [])),
       manifest_digest: Map.get(attrs, :manifest_digest),
       commands: commands,
       discovered_at: Map.get(attrs, :discovered_at) || DateTime.utc_now(),
       resolution_origin: Map.get(attrs, :resolution_origin, %{})
     }}
  end

  def new(_attrs), do: {:error, :invalid_capability_attrs}

  @doc """
  Canonical identity tuple used for cache equality and identity stability.

  Two capabilities with the same `{plugin_id, version, manifest_digest}` are
  considered the same artifact even across re-discoveries.
  """
  @spec identity(t()) :: {String.t(), String.t() | nil, String.t() | nil}
  def identity(%__MODULE__{plugin_id: id, version: version, manifest_digest: digest}) do
    {id, version, digest}
  end

  @doc """
  Finds a command on the capability by canonical name or alias.

  Returns `nil` when neither matches; callers should treat that as
  `:unknown` rather than guessing.
  """
  @spec find_command(t(), String.t()) :: CommandCapability.t() | nil
  def find_command(%__MODULE__{commands: commands}, token) when is_binary(token) do
    Enum.find(commands, fn cmd ->
      cmd.name == token or token in cmd.aliases
    end)
  end

  defp normalize_scopes(scopes) do
    scopes
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end
end
