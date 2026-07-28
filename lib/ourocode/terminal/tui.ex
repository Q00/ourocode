defmodule Ourocode.Terminal.Tui do
  @moduledoc """
  Interactive terminal frontend driver.

  This is the seed's optional, replaceable high-performance frontend piece:
  it owns raw-mode input, the alternate screen, and an in-place colored
  redraw, while the Elixir runtime stays the single source of truth. It
  attaches only at the existing `EventLoop` input/output seam, so the loop
  logic, the data/journal model, and every non-interactive (piped, smoke,
  test) path stay byte-for-byte unchanged.
  """

  alias Ourocode.Terminal.{
    ShellRenderer,
    TuiDriverSession,
    TuiEnvironment,
    TuiCompletions,
    TuiFrame,
    TuiInputLoop,
    TuiInteraction,
    TuiLogin,
    TuiModelSelection,
    TuiState,
    TuiSubmit
  }

  @prompt "ourocode> "
  @model_cache_ttl_ms 2_000

  @doc """
  Returns true only for a real interactive terminal session.

  Piped input, captured `StringIO` devices (tests), and the non-interactive
  smoke path all fall back to the plain line renderer.
  """
  @spec interactive?(map() | keyword()) :: boolean()
  def interactive?(options), do: TuiEnvironment.interactive?(options)

  # A live ExUnit server means we are inside the test runner; never claim a
  # raw terminal there even if the developer runs `mix test` from a real tty.
  defp test_run?, do: TuiEnvironment.test_run?()

  @doc """
  Runs the interactive flow with the TUI attached to the event loop.

  The terminal is always restored, even if the loop raises or exits.
  """
  @spec run(map(), map() | keyword(), (map(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def run(result, options, loop_fun) when is_function(loop_fun, 2) do
    {:ok, output} = StringIO.open("")
    state = TuiState.start_link()

    case TuiDriverSession.start(state) do
      :ok ->
        try do
          {columns, rows} = TuiDriverSession.refresh_size(state)
          redraw(result, output, state, "", columns, rows)

          read_line = fn _prompt -> read_key_line(result, output, state) end

          loop_options =
            options
            |> Map.new()
            |> Map.put(:output, output)
            |> Map.put(:read_line, read_line)
            |> Map.put(:prompt, @prompt)
            |> Map.put(:tui_state, state)
            |> attach_live_turn_feedback(state)
            |> attach_active_model_provider(state)

          loop_fun.(result, loop_options)
        after
          TuiDriverSession.stop(state)
          StringIO.close(output)
          Agent.stop(state)
        end

      :error ->
        StringIO.close(output)
        Agent.stop(state)
        # No native helper: fall back to the plain line renderer + loop.
        ShellRenderer.draw_initial_frame(result, Map.get(Map.new(options), :output, :stdio))
        loop_fun.(result, options)
    end
  end

  defp attach_active_model_provider(options, state) do
    case Map.get(options, :on_prompt_input) do
      fun when is_function(fun, 3) ->
        Map.put(options, :on_prompt_input, fn task_request, input_event, startup_result ->
          input_event =
            input_event
            |> Map.put(:active_model, active_model(state))
            |> put_in([:payload, :active_model_id], active_model(state).id)

          fun.(task_request, input_event, startup_result)
        end)

      _other ->
        options
    end
  end

  defp attach_live_turn_feedback(options, state) do
    existing =
      Map.get(options, :on_prompt_state_change, fn _state_event, _startup_result -> :ok end)

    Map.put(options, :on_prompt_state_change, fn state_event, startup_result ->
      TuiState.put_live_turn_event(state, state_event)
      existing.(state_event, startup_result)
    end)
  end

  defp read_key_line(result, output, state) do
    TuiInputLoop.read_line(result, output, state, %{
      choose_model: &choose_model/5,
      handle_enter: &handle_enter/6,
      redraw: &redraw/6,
      test_run?: &test_run?/0
    })
  end

  @doc false
  def wonder_nav_after(detection, nav, event) do
    TuiInteraction.nav_after(detection, nav, event)
  end

  defp choose_model(result, output, state, cols, rows) do
    TuiModelSelection.choose(result, output, state, cols, rows,
      redraw: &redraw/6,
      login: &TuiLogin.start/7
    )
  end

  defp handle_enter(line, result, output, state, cols, rows) do
    TuiSubmit.handle(line, result, output, state, cols, rows,
      active_model: &active_model/1,
      redraw: &redraw/6
    )
  end

  defp active_model(state) do
    TuiModelSelection.active_model(state, @model_cache_ttl_ms)
  end

  defp auth_label(state) do
    TuiModelSelection.auth_label(state, @model_cache_ttl_ms)
  end

  # --- rendering -----------------------------------------------------------

  @doc """
  Builds the composed frame as plain text rows (no ANSI), for snapshot tests
  and previews. `frame` is the SSoT text projection from `ShellRenderer`.
  """
  @spec frame_lines(String.t(), [String.t()], String.t(), pos_integer(), pos_integer(), map()) ::
          [String.t()]
  def frame_lines(frame, activity, prompt_buffer, columns, rows, opts \\ %{})
      when is_binary(frame) and is_list(activity) and is_binary(prompt_buffer) do
    TuiFrame.frame_lines(frame, activity, prompt_buffer, columns, rows, opts)
  end

  defp redraw(result, output, state, prompt_buffer, columns, rows) do
    TuiFrame.redraw(result, output, state, prompt_buffer, columns, rows,
      auth_label: &auth_label/1,
      test_run?: &test_run?/0
    )
  end

  # The shared conversation tail, color-coded by speaker so the dialectic
  # reads at a glance: MCP (the question generator) amber, MAIN (the
  # answerer/main session's resolved turn) green, Answer (your judgment) bold.
  # `drop_trailing_mcp?` hides the open question here when the picker below
  # already renders it. Returned as {text, style} rows the block paints
  # verbatim (no '> ' / strong inference).
  @doc false
  @spec dialogue_rows(map(), boolean()) :: [{String.t(), atom()} | :rule]
  def dialogue_rows(result, drop_trailing_mcp?),
    do: Ourocode.Terminal.InterviewPanel.dialogue_rows(result, drop_trailing_mcp?)

  # The LEFT-block activity under a plain question: a single animated line
  # carrying only the latest *clean* router trace — never the raw streamed
  # model text — so the main session's work is visible without leaking the
  # ASK_USER directive protocol. Public for snapshot tests.
  @doc false
  @spec interview_working_lines(map(), integer()) :: [String.t()]
  def interview_working_lines(result, tick),
    do: Ourocode.Terminal.InterviewPanel.interview_working_lines(result, tick)

  # The active question's selection block: header (with "i/n" only when
  # multi), the question text, then each option with a ">" cursor on the
  # highlighted row. Public (snapshot tests) and deterministic for a given
  # detection + nav; [] when there is nothing to render.
  @doc false
  @spec wonder_picker_lines(map(), map() | nil) :: [String.t()]
  def wonder_picker_lines(detection, nav),
    do: Ourocode.Terminal.InterviewPanel.wonder_picker_lines(detection, nav)

  # Right-column section: MCP-internal only — what the interview engine puts
  # on the wire (ambiguity score, breakdown, milestone, seed-ready, server
  # status, session). The answerer/router reasoning is the MAIN SESSION's
  # work and lives in the LEFT block (`block_reasoning_tail/1`), never here.
  # Public for snapshot tests.
  @doc false
  def interview_reasoning_lines(result, tick \\ nil) do
    Ourocode.Terminal.InterviewPanel.interview_reasoning_lines(result, tick)
  end

  @doc false
  def mcp_activity_lines(result) do
    Ourocode.Terminal.InterviewPanel.mcp_activity_lines(result)
  end

  @doc false
  def active_file_mention_query(prompt_buffer, cursor) when is_binary(prompt_buffer) do
    TuiCompletions.active_file_mention_query(prompt_buffer, cursor)
  end

  @doc false
  @spec wrap_text(String.t(), pos_integer()) :: [String.t()]
  def wrap_text(text, width), do: Ourocode.Terminal.Renderer.wrap_text(text, width)

  # --- terminal control (native helper) ------------------------------------

  # An escript cannot reliably raw-mode its controlling terminal (`stty` via
  # :os.cmd has no usable ctty), so a tiny native helper owns the tty: it
  # sets termios raw, reports size via TIOCGWINSZ, streams keystrokes to its
  # stdout, and writes frames from its stdin to the tty. We talk to it over
  # an OS pipe (a Port), which is reliable. This is the seed's replaceable
  # native frontend piece; the Elixir runtime stays the source of truth.

  @doc "Absolute path of the built tty helper, or nil if it is not present."
  @spec helper_path() :: String.t() | nil
  def helper_path, do: TuiEnvironment.helper_path()

  @doc false
  def terminal_enter_sequence, do: TuiEnvironment.terminal_enter_sequence()

  @doc false
  def terminal_exit_sequence, do: TuiEnvironment.terminal_exit_sequence()

  @doc false
  def edit_input(buffer, cursor, event) when is_binary(buffer) and is_integer(cursor) do
    Ourocode.Terminal.InputEditor.edit_input(buffer, cursor, event)
  end
end
