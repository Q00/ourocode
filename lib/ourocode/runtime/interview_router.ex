defmodule Ourocode.Runtime.InterviewRouter do
  @moduledoc """
  SKILL Path A router: turns one MCP interview question into either a
  code/research-derived answer or a routed-to-user prompt.

  The Ouroboros MCP is a pure question generator — it cannot read code. This
  module is the "answerer + router" half of the SKILL contract:

      MCP (question generator) ←→ Router (answerer + router) ←→ User (judgment)

  `Ourocode.Model` is a plain text-stream runner (no native tool calls), so the
  agent loop is a **text protocol**: the model emits one constrained directive
  per turn and `decide/4` executes read-only tools on its behalf, feeding the
  observation back until the model commits to `ANSWER` or `ASK_USER`.

  Hard rules taken straight from `skills/interview/SKILL.md`:

    * Facts (current stack/architecture/files) are answerable from code →
      `ANSWER [from-code] …`. Research facts → `ANSWER [from-research] …`.
      Decisions / goals / acceptance criteria / tradeoffs are human judgment →
      `ASK_USER …`. When in doubt, `ASK_USER`.
    * Dialectic Rhythm Guard: after 3 consecutive non-user answers the next
      question is forced to the user even if it looks code-answerable.
    * If the answerer model is not `ready?`, every question is routed to the
      user (the SKILL Path B / #2a fallback, automatic).

  The tool sandbox is read-only and project-bounded: relative paths only, no
  `..` escape, no absolute paths, bounded read/grep output, capped turns.
  """

  alias Ourocode.Model

  @max_turns 6
  @max_read_bytes 32_768
  @max_glob_hits 100
  @max_grep_bytes 8_192
  @grep_timeout_ms 5_000

  @type source :: :code | :research | :user
  @type option :: %{label: String.t(), description: String.t()}
  @type decision ::
          {:answer, String.t(), source()}
          | {:ask_user, String.t(), [option()]}
          | {:error, term()}

  @doc """
  Decides how to handle one MCP interview question.

  `ctx` carries at least `:project_dir` (read-only sandbox root) and `:streak`
  (consecutive non-user answers, for the Dialectic Rhythm Guard). `model` is an
  `Ourocode.Model.t()`; when it is not `ready?` every question is routed to the
  user. Sinks (optional `(binary -> any)`):

    * `opts[:on_trace]` — one compact line per router PATH decision / tool
      activity.
    * `opts[:on_reason]` — the answerer model's streamed reasoning chunks as
      they arrive (the main session's live thinking). Surfaced in the LEFT
      transcript block; never discarded.

  `ASK_USER` carries up to 4 model-suggested options so it can be presented
  as a wonderTool checkpoint (SKILL PATH 2 "with suggested options").
  """
  @spec decide(String.t(), map(), Model.t(), keyword()) :: decision()
  def decide(question, ctx, model, opts \\ [])

  def decide(question, ctx, %Model{} = model, opts)
      when is_binary(question) and is_map(ctx) and is_list(opts) do
    io = %{trace: sink(opts, :on_trace), reason: sink(opts, :on_reason)}
    question = clean_question(question)

    cond do
      not Model.ready?(model) ->
        io.trace.("PATH 2 (model unavailable → user): #{truncate(question, 80)}")
        {:ask_user, question, []}

      dialectic_guard_tripped?(ctx) ->
        io.trace.("PATH 2 (Dialectic Rhythm Guard, 3 non-user answers): forced to user")
        {:ask_user, question, []}

      true ->
        project_dir = sandbox_root(ctx)
        loop(model, question, project_dir, [], 1, io)
    end
  rescue
    exception -> {:error, {:router_exception, Exception.message(exception)}}
  end

  def decide(_question, _ctx, _model, _opts), do: {:error, :invalid_router_args}

  defp clean_question(question) do
    question
    |> String.replace(~r/(\*\*|__)(.*?)\1/s, "\\2")
    |> String.replace(~r/`([^`]+)`/, "\\1")
    |> String.trim()
  end

  # --- agent loop ----------------------------------------------------------

  defp loop(_model, question, _root, _obs, turn, io) when turn > @max_turns do
    io.trace.("PATH 2 (turn cap #{@max_turns} reached → user): when in doubt, ask")
    {:ask_user, question, []}
  end

  defp loop(model, question, root, observations, turn, io) do
    prompt = build_prompt(question, observations, turn)
    on_chunk = fn chunk -> if is_binary(chunk) and chunk != "", do: io.reason.(chunk) end

    case Model.stream(model, prompt, [], on_chunk) do
      {:ok, text} ->
        text
        |> parse_directive()
        |> dispatch(model, question, root, observations, turn, io)

      {:error, reason} ->
        {:error, {:model_failed, reason}}
    end
  end

  defp dispatch({:answer, payload}, _model, _q, _root, _obs, _turn, io) do
    source = source_of(payload)
    io.trace.("ANSWER [#{source}]: #{truncate(payload, 80)}")
    {:answer, payload, source}
  end

  defp dispatch({:ask_user, prompt, options}, _model, _q, _root, _obs, _turn, io) do
    io.trace.("ASK_USER (#{length(options)} opt): #{truncate(prompt, 80)}")
    {:ask_user, prompt, options}
  end

  defp dispatch({:tool, tool, arg}, model, question, root, observations, turn, io) do
    {label, observation} = run_tool(tool, arg, root)
    io.trace.("TOOL #{label} (turn #{turn})")
    loop(model, question, root, observations ++ [{label, observation}], turn + 1, io)
  end

  defp dispatch(:unparseable, model, question, root, observations, turn, io) do
    # A malformed turn is not fatal: nudge once with an explicit reminder, then
    # fall back to ASK_USER via the turn cap. Never invent a routing decision.
    io.trace.("router: unparseable model output (turn #{turn}) — reprompting")

    loop(
      model,
      question,
      root,
      observations ++ [{"FORMAT", "Previous reply was not a valid directive."}],
      turn + 1,
      io
    )
  end

  # --- directive parser ----------------------------------------------------

  @doc false
  @spec parse_directive(String.t()) ::
          {:answer, String.t()}
          | {:ask_user, String.t(), [option()]}
          | {:tool, atom(), String.t()}
          | :unparseable
  def parse_directive(text) when is_binary(text) do
    {line, directive_text} = first_directive_segment(text)

    cond do
      match = Regex.run(~r/\ATOOL\s+READ\s+(.+)\z/s, line) ->
        {:tool, :read, String.trim(Enum.at(match, 1))}

      match = Regex.run(~r/\ATOOL\s+GLOB\s+(.+)\z/s, line) ->
        {:tool, :glob, String.trim(Enum.at(match, 1))}

      match = Regex.run(~r/\ATOOL\s+GREP\s+(.+)\z/s, line) ->
        {:tool, :grep, String.trim(Enum.at(match, 1))}

      String.match?(line, ~r/\AANSWER\b/) ->
        {:answer, payload_after(directive_text, line, "ANSWER")}

      String.match?(line, ~r/\AASK_USER\b/) ->
        parse_ask_user(payload_after(directive_text, line, "ASK_USER"))

      true ->
        :unparseable
    end
  end

  def parse_directive(_text), do: :unparseable

  @option_re ~r/\A[-*]\s*(.+?)\s*[|｜]\s*(.+)\z/

  # ASK_USER body = a question, optionally followed by up to 4 suggested
  # option lines `- <label> | <description>`. The options let the loop
  # present it as a wonderTool checkpoint (SKILL PATH 2 "with suggested
  # options"); 0 options is valid (the caller pads to the wonderTool minimum).
  defp parse_ask_user(body) do
    lines = String.split(body, "\n")
    {opt_lines, q_lines} = Enum.split_with(lines, &Regex.match?(@option_re, String.trim(&1)))

    options =
      opt_lines
      |> Enum.map(fn l ->
        [_, label, desc] = Regex.run(@option_re, String.trim(l))
        %{label: String.trim(label), description: String.trim(desc)}
      end)
      |> Enum.take(4)

    prompt =
      q_lines
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
      |> String.trim()

    {:ask_user, prompt, options}
  end

  @directive_re ~r/\A(?:TOOL\s+(?:READ|GLOB|GREP)\b|ANSWER\b|ASK_USER\b)/

  # The model is told to emit the directive first, but some CLI wrappers
  # prepend runner banners to stdout (Codex CLI prints a provider label and
  # appends a `tokens used` footer). Scan to the first directive and discard
  # known footers so strict routing survives real provider wrappers without
  # accepting arbitrary prose as a decision.
  defp first_directive_segment(text) do
    lines =
      text
      |> strip_echoed_prompt()
      |> String.split("\n", trim: false)

    case Enum.find_index(lines, &(String.trim(&1) =~ @directive_re)) do
      nil ->
        {"", ""}

      index ->
        segment_lines =
          lines
          |> Enum.drop(index)
          |> Enum.take_while(&(not cli_footer_line?(&1)))

        line =
          segment_lines
          |> Enum.map(&String.trim/1)
          |> Enum.find("", &(&1 != ""))

        {line, Enum.join(segment_lines, "\n")}
    end
  end

  defp strip_echoed_prompt(text) do
    case Regex.split(~r/^\s*## Your reply\s*$/m, text, parts: 2) do
      [_before, after_marker] -> after_marker
      _no_marker -> text
    end
  end

  defp cli_footer_line?(line) do
    String.trim(line) in ["tokens used"]
  end

  defp payload_after(full_text, first_line, keyword) do
    rest_of_first = String.replace_prefix(first_line, keyword, "") |> String.trim_leading()

    tail =
      case String.split(full_text, "\n", parts: 2) do
        [_only] -> ""
        [_first, rest] -> rest
      end
      |> String.trim_trailing()

    [rest_of_first, tail]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> String.trim()
  end

  defp source_of(payload) do
    cond do
      String.contains?(payload, "[from-research]") -> :research
      String.contains?(payload, "[from-user]") -> :user
      true -> :code
    end
  end

  # --- read-only, project-bounded tool sandbox -----------------------------

  defp run_tool(:read, rel, root) do
    case safe_path(rel, root) do
      {:ok, abs} ->
        case File.read(abs) do
          {:ok, bin} -> {"READ #{rel}", cap_bytes(bin, @max_read_bytes)}
          {:error, reason} -> {"READ #{rel}", "error: #{:file.format_error(reason)}"}
        end

      {:error, why} ->
        {"READ #{rel}", "rejected: #{why}"}
    end
  end

  defp run_tool(:glob, pat, root) do
    case safe_relative?(pat) do
      :ok ->
        hits =
          Path.join(root, pat)
          |> Path.wildcard()
          |> Enum.map(&Path.relative_to(&1, root))
          |> Enum.take(@max_glob_hits)

        body = if hits == [], do: "(no matches)", else: Enum.join(hits, "\n")
        {"GLOB #{pat}", body}

      {:error, why} ->
        {"GLOB #{pat}", "rejected: #{why}"}
    end
  end

  defp run_tool(:grep, arg, root) do
    {pattern, glob} = split_grep_arg(arg)

    cond do
      pattern == "" ->
        {"GREP #{arg}", "rejected: empty pattern"}

      glob != nil and match?({:error, _}, safe_relative?(glob)) ->
        {"GREP #{arg}", "rejected: unsafe glob"}

      true ->
        {"GREP #{arg}", bounded_grep(pattern, glob, root)}
    end
  end

  defp run_tool(_tool, arg, _root), do: {"UNKNOWN #{inspect(arg)}", "rejected: unknown tool"}

  defp bounded_grep(pattern, glob, root) do
    args =
      ["-rnI", "--"]
      |> then(fn base -> if glob, do: ["--include=" <> glob | base], else: base end)
      |> Kernel.++([pattern, "."])

    task =
      Task.async(fn ->
        System.cmd("grep", args, cd: root, stderr_to_stdout: true)
      end)

    case Task.yield(task, @grep_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, status}} when status in [0, 1] ->
        if String.trim(out) == "", do: "(no matches)", else: cap_bytes(out, @max_grep_bytes)

      {:ok, {out, _status}} ->
        "error: " <> cap_bytes(out, 256)

      _timeout_or_crash ->
        "error: grep timed out"
    end
  rescue
    _exception -> "error: grep unavailable"
  end

  defp split_grep_arg(arg) do
    case String.split(String.trim(arg), ~r/\s+/, parts: 2) do
      [pattern] -> {pattern, nil}
      [pattern, glob] -> {pattern, String.trim(glob)}
      _none -> {"", nil}
    end
  end

  # Default-deny, resolve-then-contain: reject hostile literals before
  # resolving, then check containment of the resolved path. This closes the
  # TOCTOU/symlink-escape hole `Path.expand` alone leaves open: a link inside
  # the project pointing out would otherwise pass a pure string-prefix check.
  defp safe_path(rel, root) do
    with :ok <- safe_relative?(rel) do
      abs = Path.expand(rel, root)

      cond do
        not contained?(abs, root) -> {:error, "path escapes project root"}
        symlink_on_path?(rel, root) -> {:error, "symlinked path not allowed in sandbox"}
        true -> {:ok, abs}
      end
    end
  end

  defp contained?(abs, root), do: abs == root or String.starts_with?(abs, root <> "/")

  # Walk only the `rel` portion under `root`; if any existing component is a
  # symlink, reject. A read-only interview sandbox never needs to follow
  # links, so "no symlinks at all below root" is a stronger, simpler floor
  # than realpath-then-contain (and root's own ancestors stay out of scope).
  defp symlink_on_path?(rel, root) do
    rel
    |> Path.split()
    |> Enum.reduce_while(root, fn part, acc ->
      next = Path.join(acc, part)

      case :file.read_link(next) do
        {:ok, _target} -> {:halt, :symlink}
        _not_a_link -> {:cont, next}
      end
    end)
    |> Kernel.==(:symlink)
  end

  defp safe_relative?(path) when is_binary(path) do
    cond do
      path == "" -> {:error, "empty path"}
      String.contains?(path, <<0>>) -> {:error, "null byte"}
      String.starts_with?(path, "/") -> {:error, "absolute path"}
      String.starts_with?(path, "~") -> {:error, "home expansion"}
      String.contains?(path, ["$", "`"]) -> {:error, "shell expansion"}
      String.starts_with?(path, ["%", "="]) -> {:error, "shell expansion"}
      String.contains?(path, "\\") -> {:error, "backslash/UNC path"}
      ".." in Path.split(path) -> {:error, "parent escape"}
      true -> :ok
    end
  end

  defp safe_relative?(_path), do: {:error, "invalid path"}

  defp cap_bytes(bin, limit) when byte_size(bin) <= limit, do: bin

  defp cap_bytes(bin, limit) do
    binary_part(bin, 0, limit) <> "\n…[truncated at #{limit} bytes]"
  end

  defp sandbox_root(ctx) do
    (ctx[:project_dir] || ctx[:cwd] || File.cwd!())
    |> Path.expand()
  end

  # --- guards / helpers ----------------------------------------------------

  defp dialectic_guard_tripped?(ctx) do
    case Map.get(ctx, :streak, 0) do
      n when is_integer(n) -> n >= 3
      _other -> false
    end
  end

  defp sink(opts, key) do
    case Keyword.get(opts, key) do
      fun when is_function(fun, 1) -> fun
      _none -> fn _line -> :ok end
    end
  end

  defp truncate(text, max) when is_binary(text) do
    flat = text |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(flat) <= max, do: flat, else: String.slice(flat, 0, max) <> "…"
  end

  # --- system prompt -------------------------------------------------------

  defp build_prompt(question, observations, turn) do
    """
    #{system_rules()}

    ## MCP question (turn #{turn}/#{@max_turns})
    #{question}

    #{observations_block(observations)}
    ## Your reply
    Output exactly one directive as the first line. No prose before it.
    """
  end

  defp observations_block([]), do: ""

  defp observations_block(observations) do
    body =
      observations
      |> Enum.map(fn {label, out} -> "### #{label}\n#{out}" end)
      |> Enum.join("\n\n")

    "## Tool observations so far\n#{body}\n"
  end

  defp system_rules do
    """
    You are the answerer/router half of an Ouroboros Socratic interview. The MCP
    server generates questions but CANNOT read code. You answer factual questions
    from the codebase and route human-judgment questions to the user.

    Routing rules (from the interview SKILL):
    - Factual question about the EXISTING stack, frameworks, dependencies, current
      patterns, architecture, or file structure → find the fact in code, then
      ANSWER prefixed `[from-code]`. Describe what exists; never prescribe what a
      new feature should do.
    - Fact only knowable from external/industry knowledge (APIs, pricing, library
      capabilities) → ANSWER prefixed `[from-research]` (state the fact plainly).
    - Goals, vision, acceptance criteria, business logic, preferences, tradeoffs,
      scope, or desired behaviour for NEW features → ASK_USER. Any question that
      mixes facts with a decision goes ASK_USER in full.
    - When in doubt, ASK_USER. It is safer to ask the user than to guess.

    Tool protocol — emit ONE directive as the first line, nothing before it:
      TOOL READ <relative/path>            read a file (read-only, project-bounded)
      TOOL GLOB <relative/glob>            list files matching a wildcard
      TOOL GREP <pattern> [include-glob]   recursive grep within the project
      ANSWER [from-code] <answer>          commit a code-derived factual answer
      ANSWER [from-research] <answer>      commit an external-knowledge fact
      ASK_USER <question for the human>    route a human-judgment question

    For ASK_USER, first digest the MCP question into a clean user-facing
    question. If the MCP text already contains examples, numbered choices, or
    candidate axes, reinterpret them semantically as suggested options instead
    of echoing the raw list inside the question.

    After the ASK_USER question line, add 2-4 suggested-answer options so
    the user can pick or free-type (SKILL PATH 2 "with suggested options"),
    one per line, exactly:
      - <short label> | <one-line description of what choosing it means>
    Make the options concrete, mutually distinct decisions a human would
    actually choose between (not "yes/no" unless the question is binary).
    Use plain text only for labels and descriptions: no emoji, icons, decorative
    symbols, markdown, or extra `|` characters except the single delimiter.

    Use TOOL turns to gather evidence before ANSWER. Keep the ANSWER faithful to
    the user's request: state facts, preserve constraints, do not compress away
    reasoning. Absolute paths, `..`, and `~` are rejected by the sandbox.
    """
  end
end
