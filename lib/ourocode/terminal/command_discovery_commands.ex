defmodule Ourocode.Terminal.CommandDiscoveryCommands do
  @moduledoc """
  Read-only slash-command renderers for command discovery.
  """

  alias Ourocode.Command.Registry, as: CommandRegistry
  alias Ourocode.Runtime.CapabilityGraph

  @actions [:show_help, :show_commands, :show_skills, :show_capabilities]
  @primary_slashes [
    "/ooo pm",
    "/ooo interview",
    "/ooo auto"
  ]
  @command_slashes ~w(
    /help /commands /verify /agents /mcp /config /theme /sandbox /sessions /resume
    /provider /model /login /plugins /approve /cancel /exit
  )

  @type action :: :show_help | :show_commands | :show_skills | :show_capabilities

  @spec handles?(term()) :: boolean()
  def handles?(action), do: action in @actions

  @spec render(action(), map(), map()) :: {:ok, map()}
  def render(:show_help, state, registry), do: render_registry(state.output, registry, :help)
  def render(:show_commands, state, registry), do: render_registry(state.output, registry, :all)

  def render(:show_skills, state, registry) do
    render_registry(state.output, registry, :skills)
  end

  def render(:show_capabilities, state, registry) do
    render_capability_graph(state.output, registry)
  end

  @spec render_capability_graph(pid(), map()) :: {:ok, map()}
  def render_capability_graph(output, registry) when is_map(registry) do
    graph = CapabilityGraph.build(registry)
    IO.puts(output, CapabilityGraph.render_text(graph))
    {:ok, %{count: graph.summary.count, graph: graph}}
  end

  @spec render_registry(pid(), map(), :all | :help | :primary | :skills) :: {:ok, map()}
  def render_registry(output, registry, filter) when is_map(registry) do
    entries =
      case filter do
        :help ->
          help_entries(CommandRegistry.entries(registry))

        :primary ->
          primary_entries(CommandRegistry.entries(registry))

        :skills ->
          CommandRegistry.query(registry,
            sources: [:local, :bundled_skill, :plugin, :dynamic_skill]
          )

        :all ->
          command_entries(CommandRegistry.entries(registry))
      end

    IO.puts(output, discovery_title(filter, length(entries)))

    if filter in [:all, :help] do
      IO.puts(output, "start here:")

      :primary
      |> entries_for_filter(registry)
      |> Enum.each(fn entry ->
        IO.puts(output, "  #{String.pad_trailing(display_command(entry), 18)} #{entry.summary}")
      end)

      IO.puts(output, if(filter == :help, do: "common:", else: "core commands:"))
    end

    render_entries(output, entries, filter)

    if filter == :help do
      IO.puts(output, "more: /commands for every command, /skills for installed skills")
    end

    {:ok, %{count: length(entries)}}
  end

  defp render_entries(output, entries, :all) do
    entries
    |> Enum.group_by(&entry_group/1)
    |> Enum.sort_by(fn {group, _entries} -> group_order(group) end)
    |> Enum.each(fn {group, grouped_entries} ->
      IO.puts(output, "#{group}:")
      render_entries(output, grouped_entries, :plain)
    end)

    IO.puts(output, "more:")
    IO.puts(output, "  /skills            Browse workflow tools and installed skills.")
    IO.puts(output, "  /help              Use exact command names for advanced tools.")
  end

  defp render_entries(output, entries, _filter) do
    Enum.each(entries, fn entry ->
      IO.puts(output, "  #{String.pad_trailing(entry.slash, 18)} #{entry.summary}")
    end)
  end

  defp entries_for_filter(:primary, registry),
    do: primary_entries(CommandRegistry.entries(registry))

  defp help_entries(entries) do
    wanted =
      ~w(/help /commands /agents /mcp /config /theme /verify /sandbox /sessions /provider /model /login /cancel)

    by_slash = Map.new(entries, &{&1.slash, &1})

    Enum.flat_map(wanted, fn slash ->
      case Map.fetch(by_slash, slash) do
        {:ok, entry} -> [entry]
        :error -> []
      end
    end)
  end

  defp command_entries(entries) do
    by_slash = Map.new(entries, &{&1.slash, &1})

    Enum.flat_map(@command_slashes, fn slash ->
      case Map.fetch(by_slash, slash) do
        {:ok, entry} -> [entry]
        :error -> []
      end
    end)
  end

  defp primary_entries(entries) do
    by_slash =
      entries
      |> guided_work_entries()
      |> Map.new(&{&1.slash, &1})

    @primary_slashes
    |> Enum.flat_map(fn slash ->
      case Map.fetch(by_slash, slash) do
        {:ok, entry} -> [entry]
        :error -> []
      end
    end)
  end

  defp guided_work_entries(entries) do
    [
      guided_entry("/ooo pm", "Shape product requirements with answer choices."),
      guided_entry("/ooo interview", "Clarify requirements through a Socratic interview."),
      guided_entry("/ooo auto", "Interview, draft a plan, then execute.")
      | entries
    ]
  end

  defp guided_entry(slash, summary) do
    %{slash: slash, summary: summary}
  end

  defp entry_group(%{category: :discovery}), do: "discover"
  defp entry_group(%{category: :runtime}), do: "control"
  defp entry_group(%{category: :status}), do: "inspect"
  defp entry_group(%{category: :journal}), do: "resume"

  defp entry_group(%{source: source}) when source in [:plugin, :dynamic_skill, :bundled_skill],
    do: "workflow tools"

  defp entry_group(_entry), do: "other"

  defp group_order("discover"), do: 0
  defp group_order("control"), do: 1
  defp group_order("inspect"), do: 2
  defp group_order("resume"), do: 3
  defp group_order("workflow tools"), do: 4
  defp group_order(_group), do: 5

  defp display_command(%{slash: "/ooo " <> rest}), do: "ooo " <> rest
  defp display_command(%{slash: slash}), do: slash

  defp discovery_title(:skills, count), do: "skills: #{count} available"
  defp discovery_title(:primary, count), do: "start: #{count} guided choices"
  defp discovery_title(:help, _count), do: "help"
  defp discovery_title(:all, count), do: "commands: #{count} core"
end
