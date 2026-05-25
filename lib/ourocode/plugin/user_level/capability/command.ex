defmodule Ourocode.Plugin.UserLevel.Capability.Command do
  @moduledoc """
  Per-command capability metadata declared by an installed UserLevel plugin.

  This struct is read-only and never owns trust state, execution, or storage
  paths. Trust and execution live in Ouroboros; storage paths are derived from
  `expected_artifacts` glob declarations the plugin itself publishes.
  """

  @enforce_keys [:name]
  defstruct name: nil,
            aliases: [],
            summary: nil,
            args: [],
            risk_class: :unknown,
            expected_artifacts: [],
            continuation_hint: :none

  @type risk_class :: :read_only | :handoff_producing | :destructive | :unknown
  @type continuation_hint :: :none | :suggest_run | :auto_run_when_requested
  @type arg :: %{
          required(:name) => String.t(),
          required(:required?) => boolean(),
          required(:repeatable?) => boolean(),
          required(:description) => String.t()
        }

  @type t :: %__MODULE__{
          name: String.t(),
          aliases: [String.t()],
          summary: String.t() | nil,
          args: [arg()],
          risk_class: risk_class(),
          expected_artifacts: [String.t()],
          continuation_hint: continuation_hint()
        }

  @doc """
  Builds a `Command` capability from a normalized descriptor.

  Returns `{:error, :invalid_command_attrs}` when `name` is missing or blank
  so the registry can drop the descriptor without aborting discovery of the
  surrounding plugin.
  """
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_command_attrs}
  def new(%{name: name} = attrs) when is_binary(name) and name != "" do
    {:ok,
     %__MODULE__{
       name: name,
       aliases: normalize_aliases(Map.get(attrs, :aliases, [])),
       summary: normalize_summary(Map.get(attrs, :summary)),
       args: normalize_args(Map.get(attrs, :args, [])),
       risk_class: normalize_risk(Map.get(attrs, :risk_class, :unknown)),
       expected_artifacts: normalize_artifacts(Map.get(attrs, :expected_artifacts, [])),
       continuation_hint: normalize_continuation(Map.get(attrs, :continuation_hint, :none))
     }}
  end

  def new(_attrs), do: {:error, :invalid_command_attrs}

  defp normalize_aliases(aliases) do
    aliases
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_summary(nil), do: nil
  defp normalize_summary(value) when is_binary(value), do: value
  defp normalize_summary(_other), do: nil

  defp normalize_args(args) do
    args
    |> List.wrap()
    |> Enum.map(&normalize_arg/1)
    |> Enum.reject(&(&1.name == ""))
  end

  defp normalize_arg(%{name: name} = attrs) when is_binary(name) do
    %{
      name: name,
      required?: truthy?(Map.get(attrs, :required?, Map.get(attrs, :required, false))),
      repeatable?: truthy?(Map.get(attrs, :repeatable?, Map.get(attrs, :repeatable, false))),
      description: to_description(Map.get(attrs, :description, ""))
    }
  end

  defp normalize_arg(name) when is_binary(name) do
    %{name: name, required?: false, repeatable?: false, description: ""}
  end

  defp normalize_arg(_other),
    do: %{name: "", required?: false, repeatable?: false, description: ""}

  defp normalize_artifacts(artifacts) do
    artifacts
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_risk(value)
       when value in [:read_only, :handoff_producing, :destructive, :unknown],
       do: value

  defp normalize_risk("read_only"), do: :read_only
  defp normalize_risk("handoff_producing"), do: :handoff_producing
  defp normalize_risk("destructive"), do: :destructive
  defp normalize_risk(_other), do: :unknown

  defp normalize_continuation(value)
       when value in [:none, :suggest_run, :auto_run_when_requested],
       do: value

  defp normalize_continuation("none"), do: :none
  defp normalize_continuation("suggest_run"), do: :suggest_run
  defp normalize_continuation("auto_run_when_requested"), do: :auto_run_when_requested
  defp normalize_continuation(_other), do: :none

  defp to_description(value) when is_binary(value), do: value
  defp to_description(_other), do: ""

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_other), do: false
end
