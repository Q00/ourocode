defmodule Ourocode.Command.Registry.SkillLoaderTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.Registry.SkillLoader

  test "discovers child skill manifests in deterministic order" do
    root = unique_tmp_dir()
    File.mkdir_p!(Path.join(root, "beta"))
    File.mkdir_p!(Path.join(root, "alpha"))
    File.mkdir_p!(Path.join(root, "notes"))
    File.write!(Path.join([root, "beta", "SKILL.md"]), "# Beta\n")
    File.write!(Path.join([root, "alpha", "SKILL.md"]), "# Alpha\n")
    File.write!(Path.join([root, "notes", "README.md"]), "# Notes\n")

    assert SkillLoader.discover_files(root) == [
             %{
               root: Path.expand(root),
               dir: Path.expand(Path.join(root, "alpha")),
               file: Path.expand(Path.join([root, "alpha", "SKILL.md"]))
             },
             %{
               root: Path.expand(root),
               dir: Path.expand(Path.join(root, "beta")),
               file: Path.expand(Path.join([root, "beta", "SKILL.md"]))
             }
           ]
  after
    cleanup_tmp_dir()
  end

  test "parses simple scalar frontmatter and ignores comments or malformed lines" do
    lf_frontmatter = """
    ---
    name: "ship-it"
    description: Prepare: release checklist
    # ignored: true

    malformed
    mcp_tool: release_planner
    ---

    # Body
    """

    expected = %{
      "name" => "\"ship-it\"",
      "description" => "Prepare: release checklist",
      "mcp_tool" => "release_planner"
    }

    assert SkillLoader.parse_frontmatter(lf_frontmatter) == expected

    crlf_frontmatter = String.replace(lf_frontmatter, "\n", "\r\n")
    assert SkillLoader.parse_frontmatter(crlf_frontmatter) == expected

    assert SkillLoader.parse_frontmatter("# No frontmatter") == %{}
    assert SkillLoader.parse_frontmatter("---\nname: missing-close") == %{}
  end

  test "normalizes local and bundled skills into registry entries" do
    root = unique_tmp_dir()
    skill_dir = Path.join(root, "Ship It")
    File.mkdir_p!(skill_dir)

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: "Ship It"
    description: "Prepare a release checklist."
    mcp_tool: release_planner
    ---

    # Ship It
    """)

    assert [local] = SkillLoader.entries(root, :local)
    assert [bundled] = SkillLoader.entries([root], :bundled_skill)

    assert local.id == "local_skill:ship-it"
    assert local.name == "ship-it"
    assert local.slash == "/ship-it"
    assert local.source == :local
    assert local.source_id == Path.expand(root)
    assert local.summary == "Prepare a release checklist."
    assert local.run_spec.kind == :local_skill
    assert local.run_spec.mcp_tool == "release_planner"
    assert local.metadata.distribution == :local
    assert local.metadata.frontmatter_keys == ["description", "mcp_tool", "name"]

    assert bundled.id == "bundled_skill:ship-it"
    assert bundled.source == :bundled_skill
    assert bundled.run_spec.kind == :bundled_skill
    assert bundled.metadata.distribution == :bundled
  after
    cleanup_tmp_dir()
  end

  defp unique_tmp_dir do
    dir =
      Path.join(System.tmp_dir!(), "ourocode-skill-loader-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    Process.put(:tmp_dir, dir)
    dir
  end

  defp cleanup_tmp_dir do
    if dir = Process.get(:tmp_dir) do
      File.rm_rf!(dir)
      Process.delete(:tmp_dir)
    end
  end
end
