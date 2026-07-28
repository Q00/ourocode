defmodule Ourocode.Terminal.TuiFrame do
  @moduledoc """
  Frame composition and redraw helpers for the interactive TUI.
  """

  alias Ourocode.Dashboard.{Layout, ScrollbackLedger}

  alias Ourocode.Terminal.{
    Palette,
    InterviewPanel.QuestionLedger,
    LiveResult,
    LiveTurnActivity,
    RendererInterview,
    RuntimeSplit,
    Screen,
    ScreenStyles,
    ShellRenderer,
    Suggestions,
    TuiCompletions,
    TuiDriverSession,
    TuiInteraction,
    TuiModelSelection,
    TuiState,
    WorkspaceText
  }

  @min_width 40
  @min_height 16

  @spec frame_lines(String.t(), [String.t()], String.t(), pos_integer(), pos_integer(), map()) ::
          [String.t()]
  def frame_lines(frame, activity, prompt_buffer, columns, rows, opts \\ %{})
      when is_binary(frame) and is_list(activity) and is_binary(prompt_buffer) do
    workspace_active? = workspace_active_from_opts?(opts)
    activity = opts_workspace_activity(opts) || activity
    opts = Map.put(opts, :workspace_active, workspace_active?)

    frame
    |> parse_sections()
    |> then(&compose(columns, rows, &1, activity, prompt_buffer, opts))
    |> Screen.to_lines()
  end

  @spec redraw(map(), pid(), pid(), String.t(), pos_integer(), pos_integer(), keyword()) :: :ok
  def redraw(result, output, state, prompt_buffer, columns, rows, opts \\ []) do
    TuiState.bump_tick(state)

    result =
      result
      |> LiveResult.result()
      |> display_result(state)
      |> Map.delete(:pane_snapshot)

    sections = parse_sections(ShellRenderer.render_initial_frame(result))
    activity = workspace_activity(state) || activity_lines(output)

    nav = sync_wonder_nav(state, result)
    result = sync_interview_ledger_pointer_state(result, state)

    interview_block = interview_block_lines(result, nav, TuiState.tick(state))
    interview_reasoning = interview_reasoning_lines(result, TuiState.tick(state))
    mcp_activity = mcp_activity_lines(result)
    mcp_projection = sync_mcp_ledger_pointer_state(result, state)
    workflow = get_in(result, [:runtime, :workflow]) || %{}

    view_opts =
      state
      |> view_opts(opts)
      |> Map.put(:interview_block, interview_block)
      |> Map.put(:interview_reasoning, interview_reasoning)
      |> Map.put(:question_summary, question_summary(result))
      |> Map.put(:mcp_activity, mcp_activity)
      |> Map.put(:runtime_split, mcp_projection)
      |> Map.put(:workflow, workflow)
      |> Map.put(
        :wonder_focus,
        TuiInteraction.wonder_active?(result) and not TuiInteraction.paused?(result)
      )
      |> Map.put(:interview_paused, TuiInteraction.paused?(result))
      |> Map.put(:workspace_active, TuiState.workspace_active?(state))

    sync_interview_ledger_hit_map(state, result, interview_block, columns, rows, view_opts)
    sync_mcp_ledger_hit_map(state, sections, interview_block, columns, rows, view_opts)
    maybe_complete_live_turn(state, view_opts)

    screen = compose(columns, rows, sections, activity, prompt_buffer, view_opts)

    theme = ScreenStyles.theme()
    previous_screen = previous_screen_for_theme(state, theme)
    {iodata, screen} = Screen.diff(previous_screen, screen)
    TuiState.put_prev_screen(state, screen)
    TuiState.put_render_theme(state, theme)
    write_frame(state, iodata)
    cursor_to_prompt(state, rows, columns, prompt_buffer, view_opts)
  end

  # An unchanged frame writes nothing to the tty. A changed frame is wrapped
  # in synchronized-output marks (CSI ?2026) so the terminal presents the row
  # patch atomically instead of tearing mid-frame; terminals without the mode
  # ignore the private sequences and the tty helper passes them through
  # verbatim.
  defp write_frame(_state, []), do: :ok

  defp write_frame(state, iodata) do
    TuiDriverSession.write(state, ["\e[?2026h", iodata, "\e[?2026l"])
  end

  @doc false
  @spec previous_screen_for_theme(pid(), :dark | :light) :: term() | nil
  def previous_screen_for_theme(state, theme) do
    if TuiState.render_theme(state) == theme do
      TuiState.prev_screen(state)
    end
  end

  defp display_result(result, state) do
    cond do
      TuiState.interview_cancelled?(state) ->
        result
        |> Map.delete(:wonder_tool)
        |> Map.update(:interview, nil, fn
          %{} = interview -> Map.put(interview, :complete, :user_done)
          other -> other
        end)

      TuiState.force_interview_paused?(state) ->
        Map.put(result, :paused, true)

      true ->
        result
    end
  end

  @spec view_opts(pid(), keyword()) :: map()
  def view_opts(state, opts \\ []) do
    mode = TuiState.mode(state)
    test_run? = Keyword.get(opts, :test_run?, fn -> false end)
    auth_label = Keyword.get(opts, :auth_label, fn _state -> "" end)

    %{
      mode: mode,
      login: TuiState.login(state),
      streaming: TuiState.streaming?(state),
      key_help: TuiState.key_help?(state),
      live_turn_activity:
        LiveTurnActivity.view(TuiState.live_turn_event(state), TuiState.tick(state)),
      tick: TuiState.tick(state),
      scroll: TuiState.scroll_off(state),
      pidx: TuiState.pidx(state),
      auth: auth_label.(state),
      model_status: model_status(state),
      notifications: TuiState.notifications(state),
      ooo_commands:
        if mode == :normal and Suggestions.ooo_prompt?(TuiState.buffer(state)) do
          TuiCompletions.ooo_commands(state, test_run?.())
        else
          nil
        end,
      palette:
        if mode == :palette do
          entries = Palette.filter(Palette.entries(), TuiState.buffer(state))
          %{entries: entries, index: Palette.clamp(TuiState.pidx(state), length(entries))}
        else
          nil
        end,
      model:
        if mode == :model do
          TuiModelSelection.overlay(state)
        else
          nil
        end,
      search:
        if mode == :search do
          TuiState.search_view(state)
        else
          nil
        end,
      file_mentions: TuiCompletions.file_mention_suggestions(state, mode, false)
    }
  end

  # Footer readout: which backend is active and how fast the last turn's
  # first token arrived (a CLI subprocess is multi-second; a direct API call
  # is ~1s). Latency shows only after a real turn has been timed.
  defp model_status(state) do
    label = TuiModelSelection.active_model(state, 2_000).label

    case TuiState.last_turn_ms(state) do
      ms when is_integer(ms) -> "#{label} · #{format_latency(ms)}"
      _none -> label
    end
  end

  defp format_latency(ms) when ms < 1_000, do: "#{ms}ms"
  defp format_latency(ms), do: "#{Float.round(ms / 1_000, 1)}s"

  defp interview_block_lines(result, nav, tick) do
    Ourocode.Terminal.InterviewPanel.interview_block_lines(result, nav, tick)
  end

  defp sync_wonder_nav(state, result) do
    case TuiInteraction.wonder_detection(result) do
      nil ->
        TuiState.put_wonder_nav(state, nil)
        nil

      detection ->
        nav = TuiState.wonder_nav(state)
        nav = Ourocode.Terminal.InterviewPanel.default_nav(detection, nav)

        TuiState.put_wonder_nav(state, nav)
        nav
    end
  rescue
    _exception -> nil
  end

  defp sync_interview_ledger_pointer_state(result, state) do
    selected_id = TuiState.interview_ledger_selected_id(state)
    hover_id = TuiState.interview_ledger_hover_id(state)

    case Map.get(result, :interview) do
      %{} = interview ->
        valid_ids =
          interview
          |> QuestionLedger.from_interview()
          |> Map.get(:blocks, [])
          |> MapSet.new(& &1.id)

        selected_id =
          valid_pointer_id(selected_id, valid_ids, fn ->
            TuiState.put_interview_ledger_selected_id(state, nil)
          end)

        hover_id =
          valid_pointer_id(hover_id, valid_ids, fn ->
            TuiState.put_interview_ledger_hover_id(state, nil)
          end)

        interview =
          interview
          |> maybe_put_pointer_id(:selected_question_block_id, selected_id)
          |> maybe_put_pointer_id(:hovered_question_block_id, hover_id)

        Map.put(result, :interview, interview)

      _other ->
        TuiState.put_interview_ledger_selected_id(state, nil)
        TuiState.put_interview_ledger_hover_id(state, nil)
        result
    end
  end

  defp question_summary(result) do
    ledger =
      result
      |> Map.get(:interview)
      |> QuestionLedger.from_interview()

    blocks = Map.get(ledger, :blocks, [])
    total = length(blocks)

    if total > 0 do
      pending = Enum.count(blocks, &(Map.get(&1, :status) in [:pending, :generating]))
      selected_id = Map.get(ledger, :selected_block_id)

      selected_index =
        blocks
        |> Enum.find_value(fn block ->
          if Map.get(block, :id) == selected_id, do: Map.get(block, :index)
        end)
        |> Kernel.||(total)

      "Q #{selected_index}/#{total} · pending #{pending}"
    else
      ""
    end
  end

  defp valid_pointer_id(nil, _valid_ids, _clear), do: nil

  defp valid_pointer_id(id, valid_ids, clear) when is_binary(id) and is_function(clear, 0) do
    if MapSet.member?(valid_ids, id) do
      id
    else
      clear.()
      nil
    end
  end

  defp maybe_put_pointer_id(interview, _key, nil), do: interview

  defp maybe_put_pointer_id(interview, key, id) when is_binary(id),
    do: Map.put(interview, key, id)

  defp sync_mcp_ledger_pointer_state(result, state) do
    projection = mcp_ledger_projection(result, state)
    valid_ids = MapSet.new(Map.get(projection, :block_ids, []))

    selected_id =
      valid_pointer_id(TuiState.mcp_ledger_selected_id(state), valid_ids, fn ->
        TuiState.put_mcp_ledger_selected_id(state, nil)
      end)

    hover_id =
      valid_pointer_id(TuiState.mcp_ledger_hover_id(state), valid_ids, fn ->
        TuiState.put_mcp_ledger_hover_id(state, nil)
      end)

    if selected_id != Map.get(projection, :selected_id) or
         hover_id != Map.get(projection, :hover_id) do
      mcp_ledger_projection(result, state, selected_id, hover_id)
    else
      projection
    end
  end

  defp mcp_ledger_projection(result, state) do
    mcp_ledger_projection(
      result,
      state,
      TuiState.mcp_ledger_selected_id(state),
      TuiState.mcp_ledger_hover_id(state)
    )
  end

  defp mcp_ledger_projection(result, state, selected_id, hover_id) do
    case get_in(result, [:runtime]) do
      %{parent_panes: parent_panes, child_panes: child_panes}
      when is_map(parent_panes) and is_map(child_panes) ->
        hierarchy = Layout.parent_child_hierarchy(parent_panes, child_panes)
        parent_lines = mcp_parent_lines(hierarchy)
        {child_lines, block_ids} = mcp_child_lines(hierarchy, selected_id, hover_id)

        %{
          active?: parent_lines != [] or child_lines != [],
          parent_lines: parent_lines,
          child_lines: child_lines,
          block_ids: block_ids,
          selected_id: selected_id,
          hover_id: hover_id
        }

      _other ->
        TuiState.put_mcp_ledger_hit_map(state, %{})

        %{
          active?: false,
          parent_lines: nil,
          child_lines: nil,
          block_ids: [],
          selected_id: nil,
          hover_id: nil
        }
    end
  end

  defp mcp_parent_lines(%{roots: roots}) do
    roots
    |> Enum.map(fn parent ->
      tool =
        get_in(parent, [:params, :name]) ||
          get_in(parent, [:params, "name"]) ||
          Map.get(parent, :method) ||
          "tools/call"

      status = Map.get(parent, :status, "active") |> to_string()
      child_count = parent |> Map.get(:children, []) |> length()
      "MCP toolcall #{tool} · #{status} · #{child_count} child #{plural(child_count, "pane")}"
    end)
  end

  defp mcp_parent_lines(_hierarchy), do: []

  defp mcp_child_lines(%{roots: roots, orphan_children: orphans}, selected_id, hover_id) do
    children =
      roots
      |> Enum.flat_map(&Map.get(&1, :children, []))
      |> Kernel.++(orphans)

    children
    |> Enum.flat_map_reduce([], fn child, ids ->
      {lines, child_ids} = mcp_child_ledger_lines(child, selected_id, hover_id)
      {lines, ids ++ child_ids}
    end)
  end

  defp mcp_child_lines(_hierarchy, _selected_id, _hover_id), do: {[], []}

  defp mcp_child_ledger_lines(child, selected_id, hover_id) do
    header = %{
      text:
        "Child #{Map.get(child, :child_id, "session")} · #{Map.get(child, :status, "active")} · parent=#{Map.get(child, :parent_call_id, "unknown")}",
      style: :p_dim
    }

    blocks =
      child
      |> get_in([:scrollback_ledger, :blocks])
      |> case do
        blocks when is_list(blocks) -> Enum.take(blocks, -6)
        _blocks -> []
      end

    {block_lines, ids} =
      blocks
      |> Enum.flat_map_reduce([], fn block, ids ->
        selected? = block.id == selected_id
        hovered? = block.id == hover_id

        row = %{
          id: block.id,
          text: ScrollbackLedger.render_block_line(%{block | collapsed?: not selected?}),
          style: mcp_ledger_row_style(selected?, hovered?)
        }

        details =
          if selected? do
            mcp_ledger_detail_lines(block)
          else
            []
          end

        {[row | details], [block.id | ids]}
      end)

    {[header | block_lines], Enum.reverse(ids)}
  end

  defp mcp_ledger_row_style(true, _hovered?), do: :strong
  defp mcp_ledger_row_style(false, true), do: :warn
  defp mcp_ledger_row_style(false, false), do: :p_dim

  defp mcp_ledger_detail_lines(block) do
    preview =
      block
      |> Map.get(:detail_preview, "")
      |> to_string()
      |> RendererInterview.wrap_text(72)
      |> Enum.take(3)

    [
      %{
        text: "  tool #{Map.get(block, :tool_call_id) || Map.get(block, :kind)}",
        style: :p_muted
      },
      %{
        text: "  seq #{Map.get(block, :event_seq) || Map.get(block, :runtime_seq) || "stream"}",
        style: :p_muted
      }
    ] ++ Enum.map(preview, &%{text: "  payload " <> &1, style: :p_muted})
  end

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  defp sync_interview_ledger_hit_map(state, result, interview_block, width, height, opts) do
    hit_map = visible_interview_ledger_hit_map(result, interview_block, width, height, opts)
    TuiState.put_interview_ledger_hit_map(state, hit_map)
  end

  defp sync_mcp_ledger_hit_map(state, sections, interview_block, width, height, opts) do
    hit_map = visible_mcp_ledger_hit_map(sections, interview_block, width, height, opts)
    TuiState.put_mcp_ledger_hit_map(state, hit_map)
  end

  defp visible_mcp_ledger_hit_map(sections, interview_block, width, height, opts) do
    cond do
      interview_hidden_by_layout?(opts) ->
        %{}

      match?({_marker, _lines, _hint}, interview_block) ->
        %{}

      true ->
        runtime_split = Map.get(opts, :runtime_split, %{})

        if Map.get(runtime_split, :active?) == true do
          composer_rule = max(height, @min_height) - 4
          transcript_top = 4
          transcript_bottom = composer_rule - 2

          metrics =
            RuntimeSplit.layout_metrics(
              max(width, @min_width),
              transcript_top,
              transcript_bottom,
              sections,
              Map.get(opts, :interview_reasoning, []),
              Map.get(opts, :mcp_activity, []),
              runtime_split
            )

          metrics.child_rows
          |> Enum.take(metrics.child_body_h)
          |> Enum.with_index(metrics.child_top + 1)
          |> Enum.reduce(%{}, fn {row, y}, acc ->
            case row do
              %{id: id} when is_binary(id) ->
                Map.put(acc, y, %{
                  id: id,
                  x1: metrics.inner_x,
                  x2: metrics.inner_x + metrics.inner_w
                })

              _row ->
                acc
            end
          end)
        else
          %{}
        end
    end
  end

  defp visible_interview_ledger_hit_map(
         result,
         {_marker, lines, _hint},
         width,
         height,
         opts
       ) do
    if interview_hidden_by_layout?(opts) do
      %{}
    else
      interview_ledger_hit_map(result, lines, width, height, opts)
    end
  end

  defp visible_interview_ledger_hit_map(_result, _block, _width, _height, _opts), do: %{}

  defp interview_hidden_by_layout?(opts) do
    Map.get(opts, :workspace_active, false) or Map.get(opts, :palette) != nil or
      Map.get(opts, :model) != nil
  end

  defp interview_ledger_hit_map(result, lines, width, height, opts) do
    blocks =
      result
      |> Map.get(:interview)
      |> QuestionLedger.from_interview()
      |> Map.get(:blocks, [])
      |> Map.new(&{Map.get(&1, :index), Map.get(&1, :id)})

    composer_rule = max(height, @min_height) - 4
    transcript_top = 4
    transcript_bottom = composer_rule - 2

    if interview_focus?(lines, opts) do
      panel_h = max(transcript_bottom - transcript_top + 1, 1)
      max_content = max(panel_h - 5, 1)
      RendererInterview.ledger_hit_map(:focus, transcript_top, width, lines, max_content, blocks)
    else
      max_rows = max(transcript_bottom - transcript_top - 1, 1)
      RendererInterview.ledger_hit_map(:block, transcript_top, width, lines, max_rows, blocks)
    end
  end

  defp interview_focus?(lines, opts) do
    Map.get(opts, :wonder_focus, false) or
      Enum.any?(lines, fn
        {text, _style} when is_binary(text) -> decision_line?(text)
        text when is_binary(text) -> decision_line?(text)
        _other -> false
      end)
  end

  defp decision_line?(text) do
    trimmed = String.trim_leading(text)
    String.starts_with?(text, ">> [") or String.starts_with?(trimmed, "[1]")
  end

  defp interview_reasoning_lines(result, tick) do
    Ourocode.Terminal.InterviewPanel.interview_reasoning_lines(result, tick)
  end

  defp mcp_activity_lines(result) do
    Ourocode.Terminal.InterviewPanel.mcp_activity_lines(result)
  end

  defp maybe_complete_live_turn(state, opts) do
    if TuiState.live_turn_event(state) && live_turn_surface_ready?(opts) do
      TuiState.put_live_turn_event(state, nil)
    end
  end

  defp live_turn_surface_ready?(opts) do
    Map.get(opts, :workspace_active, false) or
      match?({_marker, _lines, _hint}, Map.get(opts, :interview_block)) or
      Map.get(opts, :mcp_activity, []) != [] or
      Map.get(opts, :interview_reasoning, []) != []
  end

  defp compose(columns, rows, sections, activity, prompt_buffer, opts) do
    Ourocode.Terminal.Renderer.compose(columns, rows, sections, activity, prompt_buffer, opts)
  end

  defp parse_sections(frame), do: Ourocode.Terminal.Renderer.parse_sections(frame)

  defp activity_lines(output) do
    {_input, captured} = StringIO.contents(output)

    String.split(captured, "\n", trim: true)
  end

  defp workspace_activity(state) do
    case TuiState.workspace(state) do
      workspace when is_map(workspace) ->
        workspace
        |> WorkspaceText.render()
        |> String.split("\n", trim: true)

      _none ->
        nil
    end
  end

  defp opts_workspace_activity(%{workspace: workspace}) when is_map(workspace) do
    workspace
    |> WorkspaceText.render()
    |> String.split("\n", trim: true)
  end

  defp opts_workspace_activity(_opts), do: nil

  defp workspace_active_from_opts?(%{workspace: workspace}), do: is_map(workspace)
  defp workspace_active_from_opts?(opts), do: Map.get(opts, :workspace_active, false)

  defp cursor_to_prompt(state, rows, columns, prompt_buffer, opts) do
    height = max(rows, @min_height)
    width = max(columns, @min_width)

    prefix =
      prompt_buffer |> String.graphemes() |> Enum.take(TuiState.cursor(state)) |> Enum.join()

    prompt_start_col = prompt_text_column(opts)
    ansi_row = height - 2
    ansi_col = min(prompt_start_col + Screen.text_width(prefix), width)
    TuiDriverSession.write(state, "\e[#{ansi_row};#{ansi_col}H\e[?25h")
  end

  defp prompt_text_column(opts) do
    live_activity? = Map.get(opts, :live_turn_activity, []) != []

    # RendererChrome reserves a fixed mode-chip and marker slot before the
    # editable prompt text so cursor placement remains stable across modes.
    if live_activity? or Map.get(opts, :streaming, false), do: 19, else: 17
  end
end
