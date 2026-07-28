defmodule Ourocode.Command.Registry.SkillLoader do
  @moduledoc false

  alias Ourocode.Command.RegistryEntryAdapter

  @spec entries([Path.t()] | Path.t(), :bundled_skill | :local) :: [map()]
  def entries(skill_dir, source) when is_binary(skill_dir), do: entries([skill_dir], source)

  def entries(skill_dirs, source)
      when is_list(skill_dirs) and source in [:bundled_skill, :local] do
    skill_dirs
    |> Enum.flat_map(&discover_files/1)
    |> Enum.map(&normalize!(&1, source))
    |> Enum.sort_by(& &1.slash)
  end

  @spec discover_files(Path.t()) :: [%{root: Path.t(), dir: Path.t(), file: Path.t()}]
  def discover_files(skill_dir) when is_binary(skill_dir) do
    root = Path.expand(skill_dir)

    case File.ls(root) do
      {:ok, children} ->
        children
        |> Enum.sort()
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(fn child -> %{root: root, dir: child, file: Path.join(child, "SKILL.md")} end)
        |> Enum.filter(&File.regular?(&1.file))

      {:error, _reason} ->
        []
    end
  end

  @spec parse_frontmatter(String.t()) :: map()
  def parse_frontmatter(contents) when is_binary(contents) do
    contents
    |> String.replace("\r\n", "\n")
    |> parse_normalized_frontmatter()
  end

  defp parse_normalized_frontmatter("---\n" <> rest) do
    case String.split(rest, "\n---", parts: 2) do
      [frontmatter, _body] -> parse_frontmatter_lines(frontmatter)
      [_without_closing_marker] -> %{}
    end
  end

  defp parse_normalized_frontmatter(_contents), do: %{}

  defp normalize!(%{root: root, dir: skill_dir, file: skill_file}, source) do
    metadata = skill_file |> File.read!() |> parse_frontmatter()

    name =
      metadata |> Map.get("name", Path.basename(skill_dir)) |> unquote_scalar() |> slugify_name()

    slash = normalize_slash(name)
    description = metadata |> Map.get("description", "") |> unquote_scalar()
    mcp_tool = metadata |> Map.get("mcp_tool") |> maybe_unquote_scalar()

    run_kind = run_kind(source)
    source_id = Path.expand(root)

    source_attribution = %{
      source: source,
      source_id: source_id,
      distribution: distribution(source),
      skill_path: skill_dir,
      skill_file: skill_file
    }

    run_spec =
      %{
        kind: run_kind,
        skill_path: skill_dir,
        skill_file: skill_file
      }
      |> maybe_put(:mcp_tool, mcp_tool)

    RegistryEntryAdapter.from_skill_definition!(
      %{
        name: name,
        slash: slash,
        description: description,
        mcp_tool: mcp_tool
      },
      id: "#{run_kind}:#{name}",
      source: source,
      source_id: source_id,
      source_attribution: source_attribution,
      distribution: distribution(source),
      run_kind: run_kind,
      run_spec: run_spec,
      metadata: %{
        skill_path: skill_dir,
        skill_file: skill_file,
        distribution: distribution(source),
        frontmatter_keys: Map.keys(metadata) |> Enum.sort(),
        source_attribution: source_attribution
      }
    )
  end

  defp parse_frontmatter_lines(frontmatter) do
    frontmatter
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, metadata ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          key = String.trim(key)

          if key == "" or String.starts_with?(key, "#") do
            metadata
          else
            Map.put(metadata, key, String.trim(value))
          end

        _other ->
          metadata
      end
    end)
  end

  defp normalize_slash(command) when is_binary(command) do
    command = String.trim(command)

    if String.starts_with?(command, "/") do
      command
    else
      "/#{command}"
    end
  end

  defp maybe_unquote_scalar(nil), do: nil
  defp maybe_unquote_scalar(value), do: unquote_scalar(value)

  defp unquote_scalar(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end

  defp slugify_name(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp distribution(:bundled_skill), do: :bundled
  defp distribution(:local), do: :local

  defp run_kind(:bundled_skill), do: :bundled_skill
  defp run_kind(:local), do: :local_skill
end
