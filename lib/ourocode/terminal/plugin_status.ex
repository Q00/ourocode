defmodule Ourocode.Terminal.PluginStatus do
  alias Ourocode.Terminal.EventLoopState

  @moduledoc """
  Applies plugin-config reload events to terminal loop state.
  """

  alias Ourocode.Runtime
  alias Ourocode.Terminal.PluginStatusArea

  @spec apply_reload_event(map(), map()) :: {:ok, map()} | {:error, term()}
  def apply_reload_event(%{type: :plugin_config_reload_requested} = event, state)
      when is_map(state) do
    case runtime_from_startup(state.startup_result) do
      {:ok, runtime} ->
        reload_options =
          [
            occurred_at_ms: Map.get(event, :occurred_at_ms),
            project_dir: project_dir_from_startup(state.startup_result)
          ]
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)

        case Runtime.Application.handle_plugin_config_reload(runtime, event, reload_options) do
          {:ok, reload_result} ->
            {:ok, apply_status_update(state, reload_result)}

          {:error, reason} ->
            {:error, {:recoverable_runtime_event_handler_failed, reason}}
        end

      :error ->
        {:ok, state}
    end
  end

  def apply_reload_event(%{type: :plugin_config_reloaded} = event, state) when is_map(state) do
    case status_from_reloaded_event(event) do
      {:ok, plugin_status} ->
        {:ok,
         apply_status_update(state, %{
           status: event_value(event, :status, :loaded),
           plugins: plugin_status,
           event: event
         })}

      :error ->
        {:ok, state}
    end
  end

  def apply_reload_event(_event, state), do: {:ok, state}

  @spec status_from_reloaded_event(map()) :: {:ok, map()} | :error
  def status_from_reloaded_event(event) when is_map(event) do
    configured_plugins = event_value(event, :configured_plugins, [])

    if is_list(configured_plugins) and configured_plugins != [] do
      {:ok,
       %{
         status: event_value(event, :status, :loaded),
         config_loaded?: event_value(event, :status) in [:loaded, "loaded"],
         configured_plugins: configured_plugins,
         enabled_plugins: event_value(event, :enabled_plugins, []),
         disabled_plugins: event_value(event, :disabled_plugins, []),
         plugins_by_id:
           event_value(event, :plugins_by_id, Map.new(configured_plugins, &{plugin_id(&1), &1})),
         load_transitions: event_value(event, :load_transitions, []),
         plugin_transitions:
           event_value(event, :plugin_transitions, event_value(event, :load_transitions, [])),
         last_reload:
           Map.take(event, [
             :status,
             :request_id,
             :change,
             :source,
             :occurred_at_ms,
             :reload_boundary,
             :ui_restart_required?
           ])
       }}
    else
      :error
    end
  end

  def status_from_reloaded_event(_event), do: :error

  @spec put_plugin_status(map(), map()) :: map()
  def put_plugin_status(startup_result, plugin_status) when is_map(startup_result) do
    startup_result
    |> Map.put(:plugin_status, plugin_status)
    |> put_nested_plugin_status(:runtime, plugin_status)
    |> Map.update(:context, %{plugin_status: plugin_status}, fn context ->
      context
      |> Map.put(:plugin_status, plugin_status)
      |> put_nested_plugin_status(:runtime, plugin_status)
    end)
  end

  @spec apply_status_update(map(), map()) :: map()
  def apply_status_update(state, reload_result) do
    plugin_status = Map.fetch!(reload_result, :plugins)
    reload_event = Map.fetch!(reload_result, :event)
    startup_result = put_plugin_status(state.startup_result, plugin_status)
    status_area = PluginStatusArea.render(%{runtime: %{plugin_status: plugin_status}})

    IO.puts(state.output, PluginStatusArea.render_text(status_area))

    %{
      state
      | startup_result: startup_result,
        plugin_status_updates:
          EventLoopState.remember(state.plugin_status_updates, %{
            type: :terminal_plugin_status_updated,
            event_type: :terminal_plugin_status_updated,
            source: :terminal_runtime_event_loop,
            status: Map.get(reload_result, :status),
            reload_event: reload_event,
            plugin_status: plugin_status,
            rendered_area: status_area,
            ui_restart_required?: false,
            occurred_at_ms: Map.get(reload_event, :occurred_at_ms)
          })
    }
  end

  defp runtime_from_startup(%{runtime: runtime}) when is_map(runtime), do: {:ok, runtime}

  defp runtime_from_startup(%{context: %{runtime: runtime}}) when is_map(runtime),
    do: {:ok, runtime}

  defp runtime_from_startup(_startup_result), do: :error

  defp project_dir_from_startup(%{context: %{project_dir: project_dir}})
       when is_binary(project_dir),
       do: project_dir

  defp project_dir_from_startup(%{project_dir: project_dir}) when is_binary(project_dir),
    do: project_dir

  defp project_dir_from_startup(_startup_result), do: nil

  defp event_value(map, key, default \\ nil)

  defp event_value(map, key, default) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
  end

  defp event_value(_map, _key, default), do: default

  defp plugin_id(plugin) when is_map(plugin) do
    event_value(plugin, :id) || event_value(plugin, :plugin_id) || "plugin"
  end

  defp put_nested_plugin_status(map, key, plugin_status) do
    Map.update(map, key, %{plugin_status: plugin_status}, fn
      nested when is_map(nested) -> Map.put(nested, :plugin_status, plugin_status)
      _nested -> %{plugin_status: plugin_status}
    end)
  end
end
