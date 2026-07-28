defmodule Ourocode.Runtime.InterviewRouterTest do
  @moduledoc """
  Drives the SKILL Path A router with a scripted text-stream model so the
  text-protocol tool loop, the read-only sandbox, the Dialectic Rhythm Guard,
  and the model-unavailable fallback are all deterministic.
  """

  use ExUnit.Case, async: true

  alias Ourocode.Model
  alias Ourocode.Runtime.InterviewRouter

  # A fake Model whose `run` replays scripted turns in order. Each call pops
  # the next scripted reply, so a multi-turn TOOL→ANSWER conversation is
  # reproducible without a network or a real CLI.
  defp scripted_model(replies, status \\ :ready) do
    {:ok, agent} = Agent.start_link(fn -> replies end)

    %Model{
      id: :fake,
      label: "fake",
      kind: :cli,
      status: status,
      run: fn _prompt, _opts, on_chunk ->
        reply =
          Agent.get_and_update(agent, fn
            [next | rest] -> {next, rest}
            [] -> {"ASK_USER fallback (script exhausted)", []}
          end)

        # Mirror a real text-stream backend: emit the reply as a chunk so the
        # router's on_reason sink is exercised, then return the full text.
        if is_function(on_chunk, 1), do: on_chunk.(reply)
        {:ok, reply}
      end
    }
  end

  defp ctx, do: %{project_dir: File.cwd!(), streak: 0}

  defp link_escape!(root, name) do
    link_path = Path.join(root, name)
    remove_escape_link(link_path)

    if match?({:win32, _}, :os.type()) do
      target =
        Path.join(
          System.tmp_dir!(),
          "ourocode_sbx_target_#{System.unique_integer([:positive])}"
        )

      File.rm_rf!(target)
      File.mkdir_p!(target)
      on_exit(fn -> File.rm_rf(target) end)
      on_exit(fn -> remove_escape_link(link_path) end)

      {out, status} =
        System.cmd(
          "cmd",
          ["/d", "/c", "mklink", "/J", windows_path(link_path), windows_path(target)],
          stderr_to_stdout: true
        )

      assert status == 0, out
    else
      File.ln_s!("/etc", link_path)
      on_exit(fn -> remove_escape_link(link_path) end)
    end
  end

  defp remove_sandbox_root(root) do
    remove_escape_link(Path.join(root, "escape"))
    File.rm_rf(root)
  end

  defp remove_escape_link(path) do
    if match?({:win32, _}, :os.type()) do
      System.cmd("cmd", ["/d", "/c", "rmdir", windows_path(path)], stderr_to_stdout: true)
    else
      File.rm(path)
    end
  end

  defp windows_path(path), do: path |> Path.expand() |> String.replace("/", "\\")

  test "single-turn ANSWER is parsed with its source prefix" do
    model = scripted_model(["ANSWER [from-code] Elixir 1.15 escript CLI (mix.exs)"])

    assert {:answer, payload, :code} =
             InterviewRouter.decide("What language is this project?", ctx(), model)

    assert payload =~ "[from-code]"
    assert payload =~ "Elixir 1.15"
  end

  test "research-prefixed answers report the :research source" do
    model = scripted_model(["ANSWER [from-research] Stripe allows 100 read ops/sec"])

    assert {:answer, _payload, :research} =
             InterviewRouter.decide("What is Stripe's rate limit?", ctx(), model)
  end

  test "ASK_USER routes a human-judgment question through verbatim" do
    model = scripted_model(["ASK_USER Which payment provider should we integrate?"])

    assert {:ask_user, "Which payment provider should we integrate?", _opts} =
             InterviewRouter.decide("Greenfield or brownfield?", ctx(), model)
  end

  test "human judgment questions are digested by the answerer model" do
    model =
      scripted_model([
        """
        ASK_USER Which part of the UX feels most frustrating?
        - Interview flow | It is hard to see where questions and answers belong
        - TUI polish | The layout or colors make the terminal hard to read
        """
      ])

    question = "Which moment in the current UX feels most **frustrating or rough**?"

    assert {:ask_user, prompt, options} = InterviewRouter.decide(question, ctx(), model)
    assert prompt == "Which part of the UX feels most frustrating?"
    assert Enum.map(options, & &1.label) == ["Interview flow", "TUI polish"]
  end

  test "ASK_USER carries model-suggested options (SKILL PATH 2) for wonderTool" do
    model =
      scripted_model([
        """
        ASK_USER Which payment provider should we integrate?
        - Stripe | Best subscription tooling, USD-first
        - Toss | KRW-native, required for Korean MAU
        - Decide later | Defer this until the billing scope is clearer
        """
      ])

    assert {:ask_user, prompt, options} =
             InterviewRouter.decide("payment provider?", ctx(), model)

    assert prompt == "Which payment provider should we integrate?"
    assert length(options) == 3
    assert %{label: "Stripe", description: "Best subscription tooling, USD-first"} = hd(options)
    refute prompt =~ "Stripe"
  end

  test "ASK_USER can carry four digested options from a broad MCP question" do
    model =
      scripted_model([
        """
        ASK_USER Which growth area should ourocode investigate first?
        - Adoption | Help more developers start using it
        - Product completeness | Fill missing core capabilities
        - Ecosystem | Grow plugins, contributors, and docs
        - Business model | Make the project sustainable
        """
      ])

    assert {:ask_user, prompt, options} =
             InterviewRouter.decide("What does ourocode need in order to grow?", ctx(), model)

    assert prompt == "Which growth area should ourocode investigate first?"
    assert length(options) == 4
    assert Enum.at(options, 3).label == "Business model"
  end

  test "ASK_USER streams the answerer model's reasoning to on_reason" do
    me = self()
    model = scripted_model(["thinking… this is a human decision\nASK_USER Pick the scope?"])

    assert {:ask_user, _p, _o} =
             InterviewRouter.decide("scope?", ctx(), model,
               on_reason: fn chunk -> send(me, {:reason, chunk}) end
             )

    assert_receive {:reason, chunk}
    assert chunk =~ "thinking" or chunk =~ "ASK_USER"
  end

  test "TOOL READ feeds a sandboxed file observation back, then ANSWER closes" do
    model =
      scripted_model([
        "TOOL READ mix.exs",
        "ANSWER [from-code] escript main_module is Ourocode.CLI (mix.exs)"
      ])

    traced = self()

    assert {:answer, payload, :code} =
             InterviewRouter.decide("What is the escript entrypoint?", ctx(), model,
               on_trace: fn line -> send(traced, {:trace, line}) end
             )

    assert payload =~ "Ourocode.CLI"
    assert_receive {:trace, "TOOL READ mix.exs (turn 1)"}
  end

  test "sandbox rejects parent-escape and absolute paths but keeps looping" do
    model =
      scripted_model([
        "TOOL READ ../../../etc/passwd",
        "TOOL READ /etc/passwd",
        "ASK_USER I could not read that; what should I assume?"
      ])

    assert {:ask_user, prompt, _opts} =
             InterviewRouter.decide("Where is the secret?", ctx(), model)

    assert prompt =~ "what should I assume"
  end

  test "sandbox rejects shell-expansion, backslash, and null-byte path literals" do
    model =
      scripted_model([
        "TOOL READ $HOME/.ssh/id_rsa",
        "TOOL READ lib\\..\\secret",
        "TOOL READ bad\0name",
        "ASK_USER none of those worked; what should I assume?"
      ])

    assert {:ask_user, prompt, _opts} =
             InterviewRouter.decide("Where are the keys?", ctx(), model)

    assert prompt =~ "what should I assume"
  end

  test "sandbox rejects a symlink inside the project that escapes the root" do
    root = Path.join(System.tmp_dir!(), "ourocode_sbx_#{System.unique_integer([:positive])}")
    remove_sandbox_root(root)
    File.mkdir_p!(root)
    on_exit(fn -> remove_sandbox_root(root) end)
    # A link inside the project pointing OUT — a pure string-prefix check
    # would wrongly accept `escape/anything`; resolve-then-contain rejects it.
    link_escape!(root, "escape")

    model =
      scripted_model([
        "TOOL READ escape/passwd",
        "ASK_USER the link was blocked; what should I assume?"
      ])

    assert {:ask_user, prompt, _opts} =
             InterviewRouter.decide(
               "Read the host passwd",
               %{project_dir: root, streak: 0},
               model
             )

    assert prompt =~ "what should I assume"
  end

  test "model that is not ready routes every question to the user (Path B fallback)" do
    model =
      scripted_model(["ANSWER [from-code] should never be reached"], {:needs_auth, "/login"})

    assert {:ask_user, "Greenfield or brownfield?", []} =
             InterviewRouter.decide("Greenfield or brownfield?", ctx(), model)
  end

  test "Dialectic Rhythm Guard forces ASK_USER after 3 consecutive non-user answers" do
    model = scripted_model(["ANSWER [from-code] would-be auto answer"])

    assert {:ask_user, "What framework does it use?", []} =
             InterviewRouter.decide(
               "What framework does it use?",
               %{project_dir: File.cwd!(), streak: 3},
               model
             )
  end

  test "turn cap falls back to ASK_USER when the model never commits" do
    looping = for _ <- 1..10, do: "TOOL GLOB lib/**/*.ex"
    model = scripted_model(looping)

    assert {:ask_user, "What is the architecture?", []} =
             InterviewRouter.decide("What is the architecture?", ctx(), model)
  end

  test "GREP is bounded to the project and returns matches" do
    model =
      scripted_model([
        "TOOL GREP defmodule\\ Ourocode.Runtime.InterviewRouter",
        "ANSWER [from-code] router module exists"
      ])

    assert {:answer, _payload, :code} =
             InterviewRouter.decide("Does the router module exist?", ctx(), model)
  end

  test "unparseable model output never fabricates a decision" do
    model = scripted_model(for _ <- 1..8, do: "I think the answer is probably yes ...")

    assert {:ask_user, "Some question?", []} =
             InterviewRouter.decide("Some question?", ctx(), model)
  end

  test "parser accepts directives wrapped by Codex CLI stdout banners" do
    wrapped = """
    Reading additional input from stdin...
    OpenAI Codex v0.131.0
    --------
    model: gpt-5.5
    --------
    user
    route this
    codex
    ASK_USER Which direction should we take?
    - Polish UX | Improve the current terminal flow
    - Package release | Focus on distribution
    tokens used
    7,120
    ASK_USER Which direction should we take?
    """

    assert {:ask_user, prompt, options} = InterviewRouter.parse_directive(wrapped)
    assert prompt == "Which direction should we take?"
    assert Enum.map(options, & &1.label) == ["Polish UX", "Package release"]
  end

  test "parser ignores echoed router prompt before the actual reply marker" do
    echoed = """
    You are the answerer/router half of an Ouroboros Socratic interview.

    Tool protocol — emit ONE directive as the first line, nothing before it:
      TOOL READ <relative/path>
      ANSWER [from-code] <answer>
      ANSWER [from-research] <answer>
      ASK_USER <question for the human>

    ## MCP question (turn 1/6)
    What change do you want to define?

    ## Your reply
    ASK_USER What change should this interview define?
    - Bug fix | Identify existing broken behavior
    - Feature | Define a new capability
    """

    assert {:ask_user, prompt, options} = InterviewRouter.parse_directive(echoed)
    assert prompt == "What change should this interview define?"
    assert Enum.map(options, & &1.label) == ["Bug fix", "Feature"]
  end

  test "parser splits Codex single-line ASK_USER options" do
    text =
      "ASK_USER Whose experience should the ourocode UX work improve? " <>
        "- App user UX | Improve the screens and flows used by end users " <>
        "- Developer workflow UX | Improve the CLI, agents, and coding workflow " <>
        "- Both | Cover both areas while choosing a priority"

    assert {:ask_user, prompt, options} = InterviewRouter.parse_directive(text)
    assert prompt == "Whose experience should the ourocode UX work improve?"
    assert Enum.map(options, & &1.label) == ["App user UX", "Developer workflow UX", "Both"]
    assert Enum.at(options, 1).description =~ "CLI, agents"
  end

  test "invalid arguments return a structured error, never a guess" do
    model = scripted_model(["ANSWER x"])
    assert {:error, :invalid_router_args} = InterviewRouter.decide(123, ctx(), model)
  end
end
