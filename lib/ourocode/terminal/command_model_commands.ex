defmodule Ourocode.Terminal.CommandModelCommands do
  @moduledoc """
  Product-facing provider and model command renderers.
  """

  alias Ourocode.Model
  alias Ourocode.Model.Catalog
  alias Ourocode.Terminal.{TuiState, WorkspaceText}

  @actions [:select_provider, :show_model_commands]

  @spec handles?(term()) :: boolean()
  def handles?(action), do: action in @actions

  @spec render(:select_provider | :show_model_commands, map()) :: {:ok, map()}
  def render(action, state), do: render(action, %{args: []}, state)

  @spec render(:select_provider | :show_model_commands, map(), map()) ::
          {:ok, map()} | {:error, term()}
  def render(:select_provider, _command_event, state) do
    models = Catalog.list()
    default = Catalog.default()
    workspace = provider_workspace(models, default)

    IO.puts(state.output, WorkspaceText.render(workspace))
    {:ok, %{status: :rendered, workspace: workspace, count: length(models)}}
  end

  def render(:show_model_commands, command_event, state) do
    case Map.get(command_event, :args, []) do
      [] ->
        render_model_list(state)

      [slug] ->
        select_model_slug(slug, state)

      args ->
        IO.puts(state.output, "model: use /model <slug> with exactly one slug")
        {:error, {:invalid_model_slug_args, args}}
    end
  end

  defp render_model_list(state) do
    provider_id = active_provider_id(state)
    active_slug = active_provider_model_slug(state, provider_id)
    workspace = model_command_workspace(provider_id, active_slug)

    IO.puts(state.output, WorkspaceText.render(workspace))
    status = if workspace.records == [], do: :empty, else: :rendered
    {:ok, %{status: status, workspace: workspace, count: length(workspace.records)}}
  end

  defp select_model_slug(slug, state) do
    provider_id = active_provider_id(state)

    case fetch_tui_state(state) do
      nil ->
        IO.puts(state.output, "model: cannot persist #{slug}; no active TUI state is available")
        {:error, :model_state_unavailable}

      tui_state ->
        case TuiState.put_provider_model_slug(tui_state, provider_id, slug) do
          :ok ->
            normalized = TuiState.provider_model_slug(tui_state, provider_id)
            IO.puts(state.output, "model: #{normalized} selected for #{provider_id}")
            {:ok, %{status: :selected, provider_id: provider_id, slug: normalized}}

          {:error, reason} ->
            IO.puts(state.output, model_slug_error(provider_id, slug, reason))
            {:error, {:invalid_model_slug, reason}}
        end
    end
  end

  defp provider_workspace(models, default) do
    records =
      models
      |> Enum.map(&provider_record(&1, default))

    %{
      kind: "provider",
      title: "Providers",
      status: provider_status(records),
      selected: default_record_id(default),
      records: records,
      detail: selected_detail(records, default_record_id(default)),
      actions: [
        action("login", "Sign in", "/login", "l"),
        action("detect", "Detect providers", "ourocode --detect", "d"),
        action("verify", "Run health checks", "/verify", "v")
      ],
      shortcuts: ["Up/Dn rows", "Enter select", "type to compose"],
      next: "Use /login for ChatGPT, or choose a ready CLI provider."
    }
  end

  defp model_command_workspace(provider_id, active_slug) do
    slugs = Catalog.provider_model_slugs(provider_id)
    records = Enum.map(slugs, &model_slug_record(&1, active_slug))
    selected = selected_model_record_id(active_slug, records)

    %{
      kind: "model",
      title: "#{provider_label(provider_id)} models",
      status: model_status(provider_id, active_slug, records),
      selected: selected,
      records: records,
      detail: model_detail(provider_id, records, selected),
      actions: [
        action("provider", "Choose provider", "/provider", "p"),
        action("verify", "Run health checks", "/verify", "v")
      ],
      shortcuts: ["type /model <slug>", "use /provider for backends"],
      next: model_next(provider_id, records)
    }
  end

  defp model_slug_record(%{slug: slug, label: label} = model, active_slug) do
    active? = slug == active_slug

    %{
      id: "model:" <> slug,
      title: label,
      state: if(active?, do: "active", else: "available"),
      health: if(Map.get(model, :default?, false), do: "default", else: "ready"),
      fields: %{
        slug: slug,
        command: "/model " <> slug,
        provider: Atom.to_string(Map.fetch!(model, :provider_id))
      },
      actions: [action("select", "Select model", "/model " <> slug, "Enter")]
    }
  end

  defp no_model_detail(provider_id) do
    %{
      id: "model:none",
      title: "No model list is available for #{provider_id}",
      state: "empty",
      fields: %{provider: Atom.to_string(provider_id), command: "/provider"}
    }
  end

  defp model_detail(provider_id, [], _selected), do: no_model_detail(provider_id)
  defp model_detail(_provider_id, records, selected), do: selected_detail(records, selected)

  defp provider_record(%Model{} = model, default) do
    active? = model.id == default.id

    %{
      id: provider_id(model),
      title: model.label,
      state: if(active?, do: "active", else: model_state(model.status)),
      health: model_health(model.status),
      fields: %{
        provider: model_kind(model.kind),
        status: status_text(model.status),
        controls: model_controls(model.status)
      },
      actions: model_actions(model)
    }
  end

  defp selected_detail(records, selected_id) do
    Enum.find(records, &(Map.get(&1, :id) == selected_id)) || List.first(records) ||
      %{title: "No model detected.", state: "empty", fields: %{}}
  end

  defp selected_model_record_id(active_slug, records) do
    active_id = if is_binary(active_slug), do: "model:" <> active_slug

    cond do
      Enum.any?(records, &(Map.get(&1, :id) == active_id)) -> active_id
      record = List.first(records) -> record.id
      true -> nil
    end
  end

  defp model_status(_provider_id, active_slug, [_ | _]) when is_binary(active_slug),
    do: "active #{active_slug}"

  defp model_status(_provider_id, _active_slug, [_ | _]), do: "available"
  defp model_status(provider_id, _active_slug, []), do: "no models for #{provider_id}"

  defp model_next(_provider_id, [_ | _]),
    do: "Use /model <slug> to set the active model for this provider."

  defp model_next(provider_id, []),
    do:
      "No model list is available for #{provider_id}. Use /provider to choose a provider with models."

  defp active_provider_id(state) do
    cond do
      is_pid(fetch_tui_state(state)) ->
        TuiState.model_id(fetch_tui_state(state)) || Catalog.default().id

      is_atom(get_in(state, [:active_model, :id])) ->
        get_in(state, [:active_model, :id])

      true ->
        Catalog.default().id
    end
  end

  defp active_provider_model_slug(state, provider_id) do
    case fetch_tui_state(state) do
      pid when is_pid(pid) -> TuiState.provider_model_slug(pid, provider_id)
      _other -> Catalog.default_provider_model_slug(provider_id)
    end
  end

  defp fetch_tui_state(state), do: Map.get(state, :tui_state)

  defp provider_label(provider_id) do
    provider_id
    |> Atom.to_string()
    |> String.replace("_api", "")
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp model_slug_error(provider_id, slug, :unknown_slug),
    do: "model: unknown slug #{slug} for #{provider_id}. Run /model to list available slugs."

  defp model_slug_error(provider_id, _slug, :unknown_provider),
    do:
      "model: no model list is available for #{provider_id}. Use /provider to choose another provider."

  defp model_slug_error(_provider_id, _slug, :blank_slug),
    do: "model: blank slug. Use /model <slug>."

  defp model_slug_error(_provider_id, _slug, :invalid_slug),
    do: "model: invalid slug. Use /model <slug>."

  defp provider_status(records) do
    ready = Enum.count(records, &(Map.get(&1, :health) == "ready"))
    "#{ready} ready"
  end

  defp provider_id(%Model{id: id}), do: "provider:" <> Atom.to_string(id)
  defp default_record_id(%Model{} = model), do: provider_id(model)
  defp model_kind(:oauth), do: "ChatGPT sign-in"
  defp model_kind(:cli), do: "local CLI"
  defp model_kind(kind), do: Atom.to_string(kind)

  defp model_state(:ready), do: "ready"
  defp model_state({:needs_auth, _hint}), do: "needs sign-in"
  defp model_state(:unavailable), do: "not installed"

  defp model_health(:ready), do: "ready"
  defp model_health({:needs_auth, _hint}), do: "action needed"
  defp model_health(:unavailable), do: "missing"

  defp status_text(:ready), do: "ready to use"
  defp status_text({:needs_auth, hint}), do: "sign in with #{hint}"
  defp status_text(:unavailable), do: "not installed"

  defp model_controls(:ready), do: ["select", "verify", "switch anytime"]
  defp model_controls({:needs_auth, hint}), do: [hint, "then select"]
  defp model_controls(:unavailable), do: ["install CLI", "run detect"]

  defp model_actions(%Model{status: {:needs_auth, _hint}}) do
    [action("login", "Sign in", "/login", "Enter")]
  end

  defp model_actions(%Model{status: :ready}) do
    [
      action("select", "Select provider", "/provider", "Enter"),
      action("verify", "Verify", "/verify", "v")
    ]
  end

  defp model_actions(_model), do: [action("detect", "Detect providers", "ourocode --detect", "d")]

  defp action(id, label, command, shortcut) do
    %{id: id, label: label, command: command, shortcut: shortcut, enabled: true}
  end
end
