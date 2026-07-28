defmodule Ourocode.Model.Profile do
  @moduledoc """
  Ouroboros-aligned model profiles.

  The picker still chooses the main chat model, but `ooo` workflows need a
  role-aware runtime choice: interviews and verification prefer a precision
  backend, while execution loops prefer the Codex runtime path.
  """

  alias Ourocode.Model
  alias Ourocode.Model.Catalog

  @type t :: %{
          required(:id) => atom(),
          required(:label) => String.t(),
          required(:adapter_route) => atom() | nil,
          required(:model) => Model.t(),
          required(:model_id) => atom(),
          required(:model_label) => String.t(),
          required(:llm_backend) => String.t() | nil
        }

  @precision [:claude_api, :codex, :gemini]
  @execution [:codex, :claude_api, :gemini]

  @profiles %{
    interview: {:deep_interview, "interview/precision", @precision},
    # `ooo pm` ran on the :interview profile before it became its own adapter
    # route; keep the same precision backend for the PM interview.
    pm: {:deep_interview, "interview/precision", @precision},
    seed: {:seed_plan, "seed/plan", @precision},
    evaluate: {:verify, "verify/precision", @precision},
    qa: {:verify, "verify/precision", @precision},
    auto: {:orchestrate, "auto/orchestrate", @execution},
    run: {:execute, "execute/codex", @execution},
    evolve: {:execute, "evolve/codex", @execution},
    ralph: {:execute, "ralph/codex", @execution},
    workflow: {:execute, "workflow/codex", @execution},
    lateral: {:research, "lateral/precision", @precision},
    brownfield: {:research, "brownfield/precision", @precision}
  }

  @doc "Selects the model profile for an Ouroboros adapter route."
  @spec for_route(atom() | nil, keyword()) :: t()
  def for_route(adapter_route, opts \\ []) do
    {profile_id, label, candidates} =
      Map.get(@profiles, adapter_route, {:orchestrate, "ooo/orchestrate", @execution})

    models = Keyword.get_lazy(opts, :models, &Catalog.list/0)
    active_model = Keyword.get(opts, :active_model)
    model = pick_model(models, candidates, active_model, opts)

    %{
      id: profile_id,
      label: label,
      adapter_route: adapter_route,
      model: model,
      model_id: model.id,
      model_label: model.label,
      llm_backend: llm_backend(model)
    }
  end

  @doc "Serializes the profile for workflow events and TUI state."
  @spec event_fields(t() | nil) :: map() | nil
  def event_fields(nil), do: nil

  def event_fields(%{model: %Model{}} = profile) do
    profile
    |> Map.take([:id, :label, :adapter_route, :model_id, :model_label, :llm_backend])
  end

  @doc "Product-facing label for compact TUI surfaces."
  @spec display_label(map() | nil) :: String.t() | nil
  def display_label(nil), do: nil

  def display_label(%{label: label, model_label: model_label}),
    do: display_label(label, model_label)

  def display_label(%{"label" => label, "model_label" => model_label}),
    do: display_label(label, model_label)

  def display_label(_profile), do: nil

  @doc "Short model label without account/vendor parentheticals."
  @spec short_model_label(term()) :: String.t()
  def short_model_label(label) when is_binary(label) do
    label
    |> String.replace(~r/\s*\(.+?\)\s*/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  def short_model_label(label), do: to_string(label)

  @spec llm_backend(Model.t() | term()) :: String.t() | nil
  def llm_backend(%Model{id: :codex}), do: "codex"
  def llm_backend(%Model{id: :claude_api}), do: "claude_code"
  def llm_backend(%Model{id: :gemini}), do: "gemini"
  def llm_backend(_model), do: System.get_env("OUROCODE_MCP_LLM_BACKEND")

  defp display_label(label, model_label) do
    "#{stage_name(label)} · #{runtime_name(label, model_label)}"
  end

  defp stage_name("interview/" <> _rest), do: "Socratic Interview"
  defp stage_name("seed/" <> _rest), do: "Seed Plan"
  defp stage_name("verify/" <> _rest), do: "Verify"
  defp stage_name("auto/" <> _rest), do: "Auto"
  defp stage_name("execute/" <> _rest), do: "Execute"
  defp stage_name("evolve/" <> _rest), do: "Evolve"
  defp stage_name("ralph/" <> _rest), do: "Ralph"
  defp stage_name("workflow/" <> _rest), do: "Workflow"
  defp stage_name("lateral/" <> _rest), do: "Lateral"
  defp stage_name("brownfield/" <> _rest), do: "Brownfield"
  defp stage_name(_label), do: "Ouroboros"

  defp runtime_name(label, _model_label)
       when label in [
              "execute/codex",
              "evolve/codex",
              "ralph/codex",
              "workflow/codex"
            ],
       do: "Codex Runtime"

  defp runtime_name(label, _model_label)
       when label in [
              "interview/precision",
              "verify/precision",
              "lateral/precision",
              "brownfield/precision"
            ],
       do: "Precision"

  defp runtime_name(_label, model_label), do: short_model_label(model_label)

  defp pick_model(models, candidates, active_model, opts) do
    ready_active_candidate(active_model, candidates) ||
      ready_candidate(models, candidates) ||
      ready_active(active_model) ||
      selectable_candidate(models, candidates) ||
      active_model(active_model) ||
      Keyword.get_lazy(opts, :default_model, &Catalog.default/0)
  end

  defp ready_active_candidate(%Model{id: id} = model, candidates) do
    if id in candidates and Model.ready?(model), do: model
  end

  defp ready_active_candidate(_model, _candidates), do: nil

  defp ready_candidate(models, candidates) do
    Enum.find_value(candidates, fn id ->
      case Catalog.fetch(models, id) do
        %Model{} = model -> if Model.ready?(model), do: model
        nil -> nil
      end
    end)
  end

  defp selectable_candidate(models, candidates) do
    Enum.find_value(candidates, fn id ->
      case Catalog.fetch(models, id) do
        %Model{status: :unavailable} -> nil
        %Model{} = model -> model
        nil -> nil
      end
    end)
  end

  defp ready_active(%Model{} = model), do: if(Model.ready?(model), do: model)
  defp ready_active(_model), do: nil

  defp active_model(%Model{} = model), do: model
  defp active_model(_model), do: nil
end
