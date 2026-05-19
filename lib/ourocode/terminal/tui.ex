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

  alias Ourocode.Model
  alias Ourocode.Model.Catalog
  alias Ourocode.Provider.Codex
  alias Ourocode.Command.Registry
  alias Ourocode.Runtime.CapabilityGraph
  alias Ourocode.Terminal.{KeyReader, Palette, PromptStore, Screen, ShellRenderer}

  @prompt "ourocode> "
  @min_width 40
  @min_height 16

  @doc """
  Returns true only for a real interactive terminal session.

  Piped input, captured `StringIO` devices (tests), and the non-interactive
  smoke path all fall back to the plain line renderer.
  """
  @spec interactive?(map() | keyword()) :: boolean()
  def interactive?(options) do
    options = Map.new(options)
    input = Map.get(options, :input, :stdio)
    output = Map.get(options, :output, :stdio)

    stdio_device?(input) and stdio_device?(output) and Map.get(options, :read_line) == nil and
      not test_run?() and tty?() and helper_path() != nil
  end

  # A live ExUnit server means we are inside the test runner; never claim a
  # raw terminal there even if the developer runs `mix test` from a real tty.
  defp test_run?, do: is_pid(Process.whereis(ExUnit.Server))

  @doc """
  Runs the interactive flow with the TUI attached to the event loop.

  The terminal is always restored, even if the loop raises or exits.
  """
  @spec run(map(), map() | keyword(), (map(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def run(result, options, loop_fun) when is_function(loop_fun, 2) do
    {:ok, output} = StringIO.open("")
    state = start_state()

    case start_driver(state) do
      :ok ->
        try do
          {columns, rows} = refresh_size(state)
          redraw(result, output, state, "", columns, rows)

          read_line = fn _prompt -> read_key_line(result, output, state) end

          loop_options =
            options
            |> Map.new()
            |> Map.put(:output, output)
            |> Map.put(:read_line, read_line)
            |> Map.put(:prompt, @prompt)
            |> attach_active_model_provider(state)

          loop_fun.(result, loop_options)
        after
          stop_driver(state)
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

  defp read_key_line(result, output, state) do
    {columns, rows} = refresh_size(state)
    redraw(result, output, state, buffer(state), columns, rows)
    read_key_loop(result, output, state)
  end

  defp read_key_loop(result, output, state) do
    case next_chunk(state) do
      :eof ->
        :eof

      :tick ->
        {columns, rows} = refresh_size(state)
        redraw(result, output, state, buffer(state), columns, rows)
        read_key_loop(result, output, state)

      {:ok, chunk} ->
        {columns, rows} = refresh_size(state)
        {events, leftover} = KeyReader.decode(take_leftover(state) <> chunk)
        put_leftover(state, leftover)

        case apply_events(events, result, output, state, columns, rows) do
          {:submit, line} -> line
          :exit -> :eof
          :continue -> read_key_loop(result, output, state)
        end
    end
  end

  defp apply_events([], _result, _output, _state, _columns, _rows), do: :continue

  defp apply_events([event | rest], result, output, state, columns, rows) do
    cont = fn -> apply_events(rest, result, output, state, columns, rows) end
    draw = fn -> redraw(result, output, state, buffer(state), columns, rows) end

    cond do
      match?(%{key: :ctrl_c}, event) ->
        :exit

      # A live wonderTool checkpoint is a real picker: Up/Dn move the option
      # cursor, Tab advances to the next question, and a bare 1-9 (only when
      # the composer is empty, so free-typing still works) jumps the cursor.
      interaction_capturing?(result) and wonder_active?(result) and
          wonder_nav_event?(event, buffer(state), result, state) ->
        handle_wonder_nav(event, result, state)
        draw.()
        cont.()

      # While a checkpoint is live (and not paused), Enter submits (all picks
      # for a wonderTool, or the typed free answer) and Esc pauses; every other
      # key still edits the composer so a free-text answer stays possible.
      interaction_capturing?(result) and match?(%{key: k} when k in [:enter, :escape], event) ->
        handle_interaction_event(event, result, output, state)
        draw.()
        cont.()

      true ->
        apply_normal_event(event, result, output, state, columns, rows, cont, draw)
    end
  end

  defp apply_normal_event(event, result, output, state, columns, rows, cont, draw) do
    case {get_mode(state), event} do
      {_mode, %{key: :ctrl_c}} ->
        :exit

      {_mode, %{key: k}} when k in [:cmd_plus, :cmd_minus] ->
        # The host terminal owns zoom. Refreshing size on the next redraw keeps
        # the alternate-screen layout aligned without inserting stray input.
        draw.()
        cont.()

      # --- palette mode -------------------------------------------------
      {_mode, %{key: :ctrl_g}} ->
        toggle_key_help(state)
        draw.()
        cont.()

      {:palette, %{key: :escape}} ->
        close_palette(state)
        draw.()
        cont.()

      {:palette, %{key: down}} when down in [:down, :tab] ->
        put_pidx(state, pidx(state) + 1)
        draw.()
        cont.()

      {:palette, %{key: :up}} ->
        put_pidx(state, pidx(state) - 1)
        draw.()
        cont.()

      {:palette, %{key: :enter}} ->
        line = palette_choice(state)
        close_palette(state)

        case handle_enter(line, result, output, state, columns, rows) do
          {:submit, l} -> {:submit, l}
          :continue -> cont.()
          :exit -> :exit
        end

      {:palette, %{key: :backspace}} ->
        edit_buffer(state, event)
        if buffer(state) == "", do: close_palette(state)
        put_pidx(state, 0)
        draw.()
        cont.()

      {:palette, %{key: k}}
      when k in [
             :delete,
             :left,
             :right,
             :home,
             :end,
             :ctrl_a,
             :ctrl_b,
             :ctrl_d,
             :ctrl_e,
             :ctrl_f,
             :ctrl_k,
             :ctrl_u,
             :ctrl_w,
             :ctrl_y,
             :alt_b,
             :alt_d,
             :alt_f,
             :alt_y,
             :cmd_backspace,
             :ctrl_backspace
           ] ->
        edit_buffer(state, event)
        if buffer(state) == "", do: close_palette(state)
        put_pidx(state, 0)
        draw.()
        cont.()

      {:palette, %{key: :char, char: g}} when is_binary(g) ->
        edit_buffer(state, event)
        put_pidx(state, 0)
        draw.()
        cont.()

      {:palette, %{key: :paste, char: text}} when is_binary(text) ->
        edit_buffer(state, event)
        put_pidx(state, 0)
        draw.()
        cont.()

      # --- model picker -------------------------------------------------
      {:model, %{key: :escape}} ->
        close_palette(state)
        draw.()
        cont.()

      {:model, %{key: k}} when k in [:down, :tab] ->
        put_pidx(state, pidx(state) + 1)
        draw.()
        cont.()

      {:model, %{key: :up}} ->
        put_pidx(state, pidx(state) - 1)
        draw.()
        cont.()

      {:model, %{key: :enter}} ->
        choose_model(result, output, state, columns, rows)
        cont.()

      {:model, %{key: :backspace}} ->
        close_palette(state)
        draw.()
        cont.()

      {:model, _ignored_model_key} ->
        cont.()

      # --- normal mode --------------------------------------------------
      {:normal, %{key: down}} when down in [:down, :tab, :ctrl_n] ->
        cond do
          file_mention_suggesting?(state) ->
            put_pidx(state, pidx(state) + 1)
            draw.()

          ooo_suggesting?(state) ->
            put_pidx(state, pidx(state) + 1)
            draw.()

          true ->
            move_history(state, 1)
            draw.()
        end

        cont.()

      {:normal, %{key: up}} when up in [:up, :ctrl_p] ->
        cond do
          file_mention_suggesting?(state) ->
            put_pidx(state, pidx(state) - 1)
            draw.()

          ooo_suggesting?(state) ->
            put_pidx(state, pidx(state) - 1)
            draw.()

          true ->
            move_history(state, -1)
            draw.()
        end

        cont.()

      {:normal, %{key: :char, char: "/"}} ->
        if buffer(state) == "" do
          put_mode(state, :palette)
          put_pidx(state, 0)
        end

        edit_buffer(state, event)
        reset_history_cursor(state)
        draw.()
        cont.()

      {:normal, %{key: :enter}} ->
        cond do
          file_mention_suggesting?(state) ->
            insert_file_mention_choice(state)
            put_pidx(state, 0)
            draw.()
            cont.()

          true ->
            line =
              if ooo_suggesting?(state) do
                ooo_choice(buffer(state), pidx(state), state)
              else
                String.trim(buffer(state))
              end

            _ = take_buffer(state)
            put_pidx(state, 0)
            remember_history(state, line)

            case handle_enter(line, result, output, state, columns, rows) do
              {:submit, line} -> {:submit, line}
              :continue -> cont.()
              :exit -> :exit
            end
        end

      {:normal, %{key: :backspace}} ->
        edit_buffer(state, event)
        put_pidx(state, 0)
        reset_history_cursor(state)
        draw.()
        cont.()

      {:normal, %{key: :ctrl_d}} ->
        if buffer(state) == "" do
          :exit
        else
          edit_buffer(state, event)
          put_pidx(state, 0)
          reset_history_cursor(state)
          draw.()
          cont.()
        end

      {:normal, %{key: :escape}} ->
        handle_escape_clear(state)
        draw.()
        cont.()

      {:normal, %{key: k}}
      when k in [
             :delete,
             :left,
             :right,
             :home,
             :end,
             :ctrl_a,
             :ctrl_b,
             :ctrl_e,
             :ctrl_f,
             :ctrl_k,
             :ctrl_u,
             :ctrl_w,
             :ctrl_y,
             :alt_b,
             :alt_d,
             :alt_f,
             :alt_y,
             :cmd_backspace,
             :ctrl_backspace
           ] ->
        edit_buffer(state, event)
        put_pidx(state, 0)
        reset_history_cursor(state)
        draw.()
        cont.()

      {:normal, %{key: :char, char: g}} when is_binary(g) ->
        edit_buffer(state, event)
        put_pidx(state, 0)
        reset_history_cursor(state)
        draw.()
        cont.()

      {:normal, %{key: :paste, char: text}} when is_binary(text) ->
        edit_buffer(state, event)
        put_pidx(state, 0)
        reset_history_cursor(state)
        draw.()
        cont.()

      # Scroll-back: PageUp/PageDown move the transcript window through
      # history; 0 follows the live tail. Mouse reporting stays disabled so
      # the host terminal can own drag selection and clipboard gestures.
      {_mode, %{type: :mouse, key: :wheel_up}} ->
        scroll_by(state, 3)
        draw.()
        cont.()

      {_mode, %{type: :mouse, key: :wheel_down}} ->
        scroll_by(state, -3)
        draw.()
        cont.()

      {_mode, %{key: :page_up}} ->
        scroll_by(state, 8)
        draw.()
        cont.()

      {_mode, %{key: :page_down}} ->
        scroll_by(state, -8)
        draw.()
        cont.()

      {_mode, _ignored} ->
        cont.()
    end
  end

  # Enter: a non-empty composer is a free-text answer, except explicit
  # cancel/decline text closes the active wonderTool. An empty composer submits
  # the wonderTool — every question's highlighted option in question order, in
  # one shot. Esc pauses (does not discard) so the user can talk to the main
  # session.
  defp handle_interaction_event(%{key: :enter}, result, output, state) do
    answer = String.trim(take_buffer(state))

    cond do
      answer != "" and wonder_active?(result) and cancel_answer?(answer) ->
        push_notification(state, "phase submitting - cancelling checkpoint")
        cancel = Map.get(result, :wonder_cancel)

        case cancel && cancel.(answer) do
          {:ok, _cancelled} ->
            push_notification(state, "phase accepted - checkpoint cancelled")
            log(output, "you> #{answer}")

          _other ->
            :ok
        end

      answer != "" and wonder_active?(result) ->
        push_notification(state, "phase submitting - sending free answer")
        submit = Map.get(result, :wonder_answer)

        case submit && submit.(wonder_free_text_payload(result, state, answer)) do
          {:ok, decision} ->
            push_notification(state, "phase accepted - answer captured")
            log(output, "you> #{Map.get(decision, :selected_label, answer)}")

          _other ->
            :ok
        end

      answer != "" and interview_active?(result) ->
        push_notification(state, "phase submitting - sending interview answer")
        send = Map.get(result, :interview_answer)

        case send && send.(answer) do
          {:ok, _text} ->
            push_notification(state, "phase accepted - answer captured")
            log(output, "you> #{answer}")

          _other ->
            :ok
        end

      answer != "" ->
        :ok

      wonder_active?(result) ->
        cond do
          any_free_answer_selected?(result, state) ->
            :ok

          wonder_needs_review?(result, state) ->
            put_wonder_nav(state, Map.put(wonder_nav(state), :review?, true))
            push_notification(state, "phase review - confirm answers before submit")

          true ->
            push_notification(state, "phase submitting - sending selected answers")
            submit = Map.get(result, :wonder_answer)
            selections = wonder_selections(result, state)

            case submit && submit.(selections) do
              {:ok, decision} ->
                push_notification(state, "phase accepted - answer captured")
                log(output, "you> #{Map.get(decision, :selected_label, "")}")

              _other ->
                :ok
            end
        end

      true ->
        :ok
    end
  end

  defp handle_interaction_event(%{key: :escape}, result, output, _state) do
    case Map.get(result, :wonder_pause) do
      pause when is_function(pause, 0) ->
        pause.()
        log(output, "-- interview paused (type to talk to main session)")

      _none ->
        :ok
    end
  end

  defp handle_interaction_event(_event, _result, _output, _state), do: :ok

  defp wonder_needs_review?(result, state) do
    detection = wonder_detection(result)
    qcount = detection |> wonder_questions() |> length()
    nav = wonder_nav(state)

    qcount > 1 and not Map.get(nav || %{}, :review?, false)
  end

  defp cancel_answer?(answer) when is_binary(answer) do
    answer
    |> String.downcase()
    |> String.trim()
    |> Kernel.in(["cancel", "decline", "/cancel"])
  end

  # Up/Dn are not textual input, so they must always let the user leave the
  # Free answer row. Left/Right still stay with the composer while free-typing.
  defp wonder_nav_event?(%{key: k}, _buffer, _result, _state) when k in [:up, :down],
    do: true

  # Bare 1-9 shortcuts only work while the concrete options are focused; once
  # the cursor is on the Free answer row, every character belongs to the answer
  # text.
  defp wonder_nav_event?(%{key: k}, buffer, result, state) when k in [:left, :right] do
    buffer == "" and not active_wonder_free_answer?(result, state)
  end

  defp wonder_nav_event?(%{key: :tab}, _buffer, _result, _state),
    do: true

  defp wonder_nav_event?(%{key: :char, char: " "}, buffer, result, state) do
    buffer == "" and not active_wonder_free_answer?(result, state) and
      multi_select?(active_wonder_question(result, state))
  end

  defp wonder_nav_event?(%{key: :char, char: c}, buffer, result, state)
       when is_binary(c),
       do: buffer == "" and c =~ ~r/^[1-9]$/ and not active_wonder_free_answer?(result, state)

  defp wonder_nav_event?(%{key: :char, char: c}, buffer, result, state)
       when c in ["h", "j", "k", "l"],
       do: buffer == "" and not active_wonder_free_answer?(result, state)

  defp wonder_nav_event?(_event, _buffer, _result, _state), do: false

  defp active_wonder_question(result, state) do
    detection = wonder_detection(result)
    questions = wonder_questions(detection)

    case questions do
      [] ->
        nil

      _questions ->
        nav = wonder_nav(state)
        qi = clamp_index(nav_qidx(nav), length(questions))
        Enum.at(questions, qi)
    end
  end

  defp active_wonder_free_answer?(result, state) do
    detection = wonder_detection(result)
    questions = wonder_questions(detection)

    case questions do
      [] ->
        false

      _questions ->
        nav = wonder_nav(state)
        qi = clamp_index(nav_qidx(nav), length(questions))
        question = Enum.at(questions, qi)
        opt_count = question |> Map.get(:options, []) |> length()
        current = if multi_select?(question), do: nav_cursor(nav, qi), else: nav_pick(nav, qi)

        current == opt_count
    end
  end

  defp wonder_free_text_payload(result, state, answer) do
    payload = %{"freeText" => answer}

    case active_wonder_question(result, state) do
      %{} = question ->
        case Map.get(question, :id) || Map.get(question, "id") do
          id when is_binary(id) and id != "" -> Map.put(payload, "questionId", id)
          _other -> payload
        end

      _none ->
        payload
    end
  end

  defp handle_wonder_nav(event, result, state) do
    detection = wonder_detection(result)

    case wonder_nav_after(detection, wonder_nav(state), event) do
      nil -> :ok
      nav -> put_wonder_nav(state, nav)
    end

    :ok
  end

  @doc false
  def wonder_nav_after(detection, nav, event) do
    questions = wonder_questions(detection)
    n = length(questions)

    if n > 0 do
      nav =
        nav ||
          %{
            req_id: wonder_req_id(detection),
            qidx: 0,
            cursors: default_cursors(detection),
            picks: default_picks(detection)
          }

      qi = clamp_index(nav_qidx(nav), n)
      question = Enum.at(questions, qi)
      opt_count = question |> Map.get(:options, []) |> length()
      multi? = multi_select?(question)
      current = if multi?, do: nav_cursor(nav, qi), else: nav_pick(nav, qi)

      apply_wonder_nav(event, nav, qi, n, opt_count, multi?, current)
    end
  end

  defp apply_wonder_nav(%{key: :tab}, nav, qi, n, _opts, _multi?, _current) do
    %{nav | qidx: rem(qi + 1, max(n, 1))}
  end

  defp apply_wonder_nav(%{key: :left}, nav, qi, n, _opts, _multi?, _current) do
    %{nav | qidx: Integer.mod(qi - 1, max(n, 1))}
  end

  defp apply_wonder_nav(%{key: :right}, nav, qi, n, _opts, _multi?, _current) do
    %{nav | qidx: rem(qi + 1, max(n, 1))}
  end

  defp apply_wonder_nav(%{key: :char, char: "h"}, nav, qi, n, opts, multi?, current) do
    apply_wonder_nav(%{key: :left}, nav, qi, n, opts, multi?, current)
  end

  defp apply_wonder_nav(%{key: :char, char: "l"}, nav, qi, n, opts, multi?, current) do
    apply_wonder_nav(%{key: :right}, nav, qi, n, opts, multi?, current)
  end

  defp apply_wonder_nav(%{key: :up}, nav, qi, _n, _opts, multi?, current) do
    put_cursor_or_pick(nav, qi, max(current - 1, 0), multi?)
  end

  defp apply_wonder_nav(%{key: :down}, nav, qi, _n, opt_count, multi?, current) do
    put_cursor_or_pick(nav, qi, min(current + 1, opt_count), multi?)
  end

  defp apply_wonder_nav(%{key: :char, char: "k"}, nav, qi, n, opts, multi?, current) do
    apply_wonder_nav(%{key: :up}, nav, qi, n, opts, multi?, current)
  end

  defp apply_wonder_nav(%{key: :char, char: "j"}, nav, qi, n, opts, multi?, current) do
    apply_wonder_nav(%{key: :down}, nav, qi, n, opts, multi?, current)
  end

  defp apply_wonder_nav(%{key: :char, char: " "}, nav, qi, _n, opt_count, true, _current) do
    cursor = nav_cursor(nav, qi)
    if cursor < opt_count, do: toggle_multi_pick(nav, qi, cursor), else: nav
  end

  defp apply_wonder_nav(%{key: :char, char: c}, nav, qi, _n, opt_count, multi?, _current)
       when c in ["1", "2", "3", "4", "5", "6", "7", "8", "9"] do
    idx = String.to_integer(c) - 1
    if idx < opt_count, do: put_cursor_or_pick(nav, qi, idx, multi?), else: nav
  end

  defp apply_wonder_nav(_event, nav, _qi, _n, _opts, _multi?, _current), do: nav

  defp put_cursor_or_pick(nav, qi, idx, true) do
    %{nav | cursors: Map.put(Map.get(nav, :cursors, %{}), qi, idx)}
  end

  defp put_cursor_or_pick(nav, qi, idx, false), do: put_pick(nav, qi, idx)

  defp put_pick(nav, qi, idx) do
    %{nav | picks: Map.put(Map.get(nav, :picks, %{}), qi, idx)}
  end

  defp toggle_multi_pick(nav, qi, idx) do
    picks = Map.get(nav, :picks, %{})
    selected = Map.get(picks, qi, MapSet.new())

    selected =
      if MapSet.member?(selected, idx),
        do: MapSet.delete(selected, idx),
        else: MapSet.put(selected, idx)

    %{nav | picks: Map.put(picks, qi, selected)}
  end

  # 1-based option index per question, in question order — the payload
  # LoopBindings.answer_wonder expects (a single-element list for the
  # always-1-question interview path collapses to the legacy single answer).
  defp wonder_selections(result, state) do
    questions = result |> wonder_detection() |> wonder_questions()
    nav = wonder_nav(state)

    questions
    |> Enum.with_index()
    |> Enum.map(fn {q, qi} ->
      if multi_select?(q) do
        nav_multi_pick(nav, qi)
        |> MapSet.to_list()
        |> Enum.sort()
        |> Enum.map(&(&1 + 1))
      else
        nav_pick(nav, qi) + 1
      end
    end)
  end

  defp any_free_answer_selected?(result, state) do
    questions = result |> wonder_detection() |> wonder_questions()
    nav = wonder_nav(state)

    Enum.with_index(questions)
    |> Enum.any?(fn {question, qi} ->
      opt_count = question |> Map.get(:options, []) |> length()
      current = if multi_select?(question), do: nav_cursor(nav, qi), else: nav_pick(nav, qi)
      current == opt_count
    end)
  end

  defp close_palette(state) do
    put_mode(state, :normal)
    _ = take_buffer(state)
    put_pidx(state, 0)
  end

  defp palette_choice(state) do
    entries = Palette.filter(Palette.entries(), buffer(state))

    case Palette.selected(entries, pidx(state)) do
      %{slash: slash} -> slash
      _ -> String.trim(buffer(state))
    end
  end

  defp choose_model(result, output, state, cols, rows) do
    models = Catalog.selectable(Catalog.list())
    sel = Enum.at(models, clamp_index(pidx(state), length(models)))
    close_palette(state)

    cond do
      sel == nil ->
        redraw(result, output, state, "", cols, rows)

      Model.ready?(sel) ->
        put_model_id(state, sel.id)
        log(output, "model: #{sel.label}")
        redraw(result, output, state, "", cols, rows)

      sel.id == :codex ->
        put_model_id(state, :codex)
        do_login(result, output, state, cols, rows)

      true ->
        log(output, "#{sel.label} is not ready.")
        redraw(result, output, state, "", cols, rows)
    end
  end

  # --- main session: auth + LLM -------------------------------------------

  defp handle_enter("", _result, _output, _state, _cols, _rows), do: :continue

  defp handle_enter("/login", result, output, state, cols, rows) do
    do_login(result, output, state, cols, rows)
    :continue
  end

  defp handle_enter("/logout", result, output, state, cols, rows) do
    Codex.clear()
    log(output, "Signed out of ChatGPT.")
    redraw(result, output, state, "", cols, rows)
    :continue
  end

  defp handle_enter("/clear", result, output, state, cols, rows) do
    clear_captured_output(output)
    redraw(result, output, state, "", cols, rows)
    :continue
  end

  defp handle_enter("/answer " <> answer, result, output, state, _cols, _rows) do
    answer = String.trim(answer)

    cond do
      answer == "" ->
        log(output, "usage: /answer <interview answer>")

      interview_active?(result) ->
        send = Map.get(result, :interview_answer)

        case send && send.(answer) do
          {:ok, _text} -> log(output, "you> #{answer}")
          _other -> log(output, "No active interview answer target.")
        end

      wonder_active?(result) ->
        submit = Map.get(result, :wonder_answer)

        case submit && submit.(wonder_free_text_payload(result, state, answer)) do
          {:ok, decision} -> log(output, "you> #{Map.get(decision, :selected_label, answer)}")
          _other -> log(output, "No active wonder answer target.")
        end

      true ->
        log(output, "No active interview answer target.")
    end

    :continue
  end

  defp handle_enter("/exit", _r, _o, _s, _c, _ro), do: :exit
  defp handle_enter("/quit", _r, _o, _s, _c, _ro), do: :exit

  defp handle_enter(m, result, output, state, cols, rows)
       when m in ["/model", "/models"] do
    put_mode(state, :model)
    put_pidx(state, 0)
    redraw(result, output, state, "", cols, rows)
    :continue
  end

  defp handle_enter("/" <> _ = line, _r, _o, _s, _c, _ro), do: {:submit, line}

  defp handle_enter("ooo" <> _ = line, _r, _o, _s, _c, _ro), do: {:submit, line}

  defp handle_enter(prompt, result, output, state, cols, rows) do
    chat(prompt, result, output, state, cols, rows)
    :continue
  end

  defp do_login(result, output, state, cols, rows) do
    case Codex.start_device_login() do
      {:ok, dev} ->
        put_login(state, %{code: dev.user_code, url: dev.verification_uri})
        redraw(result, output, state, "", cols, rows)
        poll_login(dev, 0, result, output, state, cols, rows)

      {:error, reason} ->
        log(output, "Login could not start: #{inspect(reason)}")
        redraw(result, output, state, "", cols, rows)
    end
  end

  @max_login_polls 80

  defp poll_login(_dev, polls, result, output, state, cols, rows)
       when polls >= @max_login_polls do
    put_login(state, nil)
    log(output, "Login timed out. Run /login to try again.")
    redraw(result, output, state, "", cols, rows)
  end

  defp poll_login(dev, polls, result, output, state, cols, rows) do
    deadline = System.monotonic_time(:millisecond) + dev.interval_ms

    case wait_or_cancel(state, deadline) do
      :cancel ->
        put_login(state, nil)
        log(output, "Login cancelled.")
        redraw(result, output, state, "", cols, rows)

      :timeout ->
        case Codex.poll_device_login(dev) do
          {:ok, tokens} ->
            put_login(state, nil)
            put_model_id(state, :codex)
            who = tokens.email || tokens.account_id || "your ChatGPT account"
            log(output, "Signed in as #{who}. model: codex (ChatGPT) - ask anything.")
            redraw(result, output, state, "", cols, rows)

          :pending ->
            redraw(result, output, state, "", cols, rows)
            poll_login(dev, polls + 1, result, output, state, cols, rows)

          {:error, reason} ->
            put_login(state, nil)
            log(output, "Login failed: #{inspect(reason)}")
            redraw(result, output, state, "", cols, rows)
        end
    end
  end

  # Sleeps until `deadline`, but stays responsive: a Ctrl-C / Esc keystroke
  # from the helper aborts the login instead of the loop blocking the whole
  # input path (which made the program impossible to quit from the card).
  defp wait_or_cancel(state, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :timeout
    else
      port = port(state)

      receive do
        {^port, {:data, data}} ->
          if String.contains?(data, <<3>>) or String.contains?(data, <<27>>),
            do: :cancel,
            else: wait_or_cancel(state, deadline)

        {^port, {:exit_status, _}} ->
          :cancel
      after
        remaining -> :timeout
      end
    end
  end

  defp chat(prompt, result, output, state, cols, rows) do
    model = active_model(state)

    cond do
      model == nil ->
        log(output, "you> #{prompt}")
        log(output, "No model available. /model to pick one, /login for ChatGPT.")
        redraw(result, output, state, "", cols, rows)

      Model.needs_auth?(model) ->
        log(output, "you> #{prompt}")
        log(output, "#{model.label} needs sign-in. /login for ChatGPT, or /model.")
        redraw(result, output, state, "", cols, rows)

      true ->
        log(output, "you> #{prompt}")
        IO.write(output, "ourocode> ")
        set_streaming(state, true)
        redraw(result, output, state, "", cols, rows)

        on_chunk = fn chunk ->
          IO.write(output, chunk)
          redraw(result, output, state, "", cols, rows)
        end

        model_prompt = maybe_paused_interview_prompt(result, prompt)

        case Model.stream(model, model_prompt, [session_id: session_id(result)], on_chunk) do
          {:ok, full} ->
            IO.write(output, "\n")
            maybe_handoff_paused_interview_answer(result, output, full)

          {:error, :not_signed_in} ->
            log(output, "\nNot connected. /login for ChatGPT.")

          {:error, reason} ->
            log(output, "\n#{model.label} error: #{inspect(reason)}")
        end

        set_streaming(state, false)
        redraw(result, output, state, "", cols, rows)
    end
  end

  defp maybe_paused_interview_prompt(result, prompt) do
    if paused?(result) and (interview_active?(result) or wonder_active?(result)) do
      """
      You are the main ourocode session. An interview checkpoint is paused so
      the user can discuss it with you before answering.

      Pending interview question:
      #{paused_interview_question(result)}

      User message:
      #{prompt}

      Reply normally. If, and only if, your reply is ready to be submitted as
      the final answer to the pending interview question, include a final line:
      INTERVIEW_ANSWER: <concise answer to submit>
      Do not include that line for clarifications, translations, explanations,
      or ordinary discussion.
      """
    else
      prompt
    end
  end

  defp paused_interview_question(result) do
    cond do
      detection = wonder_detection(result) ->
        detection
        |> wonder_questions()
        |> List.first()
        |> case do
          %{} = question -> md_text(Map.get(question, :question, ""))
          _none -> "unknown"
        end

      interview = interview_state(result) ->
        md_text(Map.get(interview, :question, "unknown"))

      true ->
        "unknown"
    end
  end

  defp maybe_handoff_paused_interview_answer(result, output, full) do
    with true <- paused?(result),
         true <- interview_active?(result) or wonder_active?(result),
         answer when is_binary(answer) <- extract_interview_answer(full),
         send when is_function(send, 1) <- Map.get(result, :interview_answer),
         {:ok, _text} <- send.(answer) do
      log(output, "-- interview answered from main session")
    else
      _other -> :ok
    end
  end

  defp extract_interview_answer(full) when is_binary(full) do
    full
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^\s*INTERVIEW_ANSWER:\s*(.+?)\s*$/u, line) do
        [_, answer] -> String.trim(answer)
        _none -> nil
      end
    end)
  end

  defp extract_interview_answer(_full), do: nil

  defp log(output, text), do: IO.puts(output, text)

  defp clear_captured_output(output) do
    StringIO.flush(output)
    :ok
  rescue
    _exception -> :ok
  end

  defp session_id(result) do
    get_in(result, [:runtime, :session_id]) || get_in(result, [:context, :runtime_session_id]) ||
      "ourocode-main"
  end

  # The live model list is re-detected each time so status (sign-in, CLI
  # availability) is always fresh; the chosen id only picks within it.
  defp active_model(state) do
    models = Catalog.list()
    Catalog.fetch(models, model_id(state)) || Catalog.default()
  end

  defp auth_label(state) do
    model = active_model(state)

    case model && model.status do
      :ready -> {"model: #{model.label}", :ok}
      {:needs_auth, hint} -> {"model: #{model.label}  #{hint}", :dim}
      _ -> {"no model  -  /model", :dim}
    end
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
    frame
    |> parse_sections()
    |> then(&compose(columns, rows, &1, activity, prompt_buffer, opts))
    |> Screen.to_lines()
  end

  defp redraw(result, output, state, prompt_buffer, columns, rows) do
    bump_tick(state)
    sections = parse_sections(ShellRenderer.render_initial_frame(live_result(result)))
    activity = activity_lines(output)

    nav = sync_wonder_nav(state, result)

    opts =
      view_opts(state)
      |> Map.put(:interview_block, interview_block_lines(result, nav, tick(state)))
      |> Map.put(:interview_reasoning, interview_reasoning_lines(result, tick(state)))
      |> Map.put(:wonder_focus, wonder_active?(result) and not paused?(result))
      |> Map.put(:interview_paused, paused?(result))

    screen = compose(columns, rows, sections, activity, prompt_buffer, opts)

    {iodata, screen} = Screen.diff(prev_screen(state), screen)
    put_prev_screen(state, screen)
    tty_write(state, iodata)
    cursor_to_prompt(state, rows, columns, prompt_buffer)
  end

  # Projects the live runtime pane snapshot (parent/child MCP panes folded by
  # the loop bindings) into the SSoT frame so streaming is visible on the
  # renderer's own cadence. Falls back to the static result if no live source
  # is attached (non-interactive, no runtime), keeping snapshot tests stable.
  defp live_result(%{pane_snapshot: snapshot} = result) when is_function(snapshot, 0) do
    %{runtime: %{parent_panes: parent, child_panes: child}} = snapshot.()

    Map.put(
      result,
      :parent_child_hierarchy,
      Ourocode.Dashboard.Layout.parent_child_hierarchy(parent, child)
    )
  rescue
    _exception -> result
  end

  defp live_result(result), do: result

  # Full live interaction snapshot (wonderTool checkpoint + interview reasoning
  # + paused flag) from the loop bindings. nil when no live source is attached.
  defp interaction_snapshot(%{pane_snapshot: snapshot}) when is_function(snapshot, 0) do
    snapshot.()
  rescue
    _exception -> nil
  end

  defp interaction_snapshot(_result), do: nil

  defp wonder_detection(result) do
    case interaction_snapshot(result) do
      %{wonder_tool: %{} = detection} -> detection
      _none -> nil
    end
  end

  defp interview_state(result) do
    case interaction_snapshot(result) do
      %{interview: %{} = interview} -> interview
      _none -> nil
    end
  end

  defp paused?(result) do
    case interaction_snapshot(result) do
      %{paused: true} -> true
      _other -> false
    end
  end

  # The sticky session: set the moment `ooo interview` is dispatched and held
  # until the interview actually ends (LoopBindings owns the lifecycle). This
  # is what keeps the UI in "interview mode" between questions and across
  # agent turns, independent of whether a question is pending right now.
  defp interview_session(result) do
    case interaction_snapshot(result) do
      %{interview_session: %{} = session} -> session
      _none -> nil
    end
  end

  defp wonder_active?(result), do: wonder_detection(result) != nil
  defp interview_active?(result), do: interview_state(result) != nil

  # Only an *unpaused* checkpoint owns answer keys; paused lets the user talk
  # to the main session normally (the skill's "Esc to pause" flow).
  defp interaction_capturing?(result) do
    (wonder_active?(result) or interview_active?(result)) and not paused?(result)
  end

  # The prominent left-column INTERVIEW block (OpenCode message-block style:
  # accent rail + marker + emphasized question, options/answer dim). nil when
  # nothing is pending. `nav` is the live selection cursor (see wonder_nav/1).
  defp interview_block_lines(result, nav, tick) do
    cond do
      detection = wonder_detection(result) ->
        # The picker owns this space while active. Long MCP questions can
        # otherwise push the selectable options below the block cap, making
        # the checkpoint look like it never rendered.
        case wonder_picker_lines(detection, nav) do
          [] ->
            nil

          picker ->
            {wonder_marker(result), picker, wonder_pick_hint(result, wonder_qcount(detection))}
        end

      _interview = interview_state(result) ->
        # Plain question / waiting: the color-coded conversation (the latest
        # MCP turn IS the open question, kept in role color — not re-printed
        # plain) plus an animated activity line so it never looks frozen and
        # the operator sees the main session working.
        lines = dialogue_rows(result, false) ++ interview_working_lines(result, tick)
        {wonder_marker(result), lines, wonder_hint(result)}

      session = interview_session(result) ->
        label = Map.get(session, :label, "ooo interview")
        spinner = if paused?(result), do: [], else: [working_line(tick, nil)]
        {wonder_marker(result), [label | spinner], interview_session_hint(result)}

      true ->
        nil
    end
  rescue
    _exception -> nil
  end

  @spin ["|", "/", "-", "\\"]

  defp spin(tick) when is_integer(tick), do: Enum.at(@spin, rem(tick, length(@spin)))
  defp spin(_tick), do: "·  "

  # The main session's current step, animated. The latest router trace
  # is a compact projection of the answerer's work. Raw routing directives
  # (ASK_USER/ANSWER/TOOL/PATH) stay out of the user-facing panel.
  defp working_line(tick, trace) do
    phase =
      if is_binary(trace) and trace != "",
        do: router_trace_label(trace),
        else: "thinking — the main session is handling this"

    spin(tick) <> " " <> phase
  end

  defp router_trace_label(trace) do
    clean = flatten_line(trace)
    upcased = String.upcase(clean)

    cond do
      String.starts_with?(upcased, "ASK_USER") ->
        "question ready — choose or type an answer in the interview block"

      answer = Regex.run(~r/^ANSWER(?:\s+\[[^\]]+\])?:\s*(.+)$/i, clean) ->
        "main session answered: " <> Enum.at(answer, 1)

      String.starts_with?(upcased, "ANSWER") ->
        "main session answered from context"

      String.starts_with?(upcased, "TOOL") ->
        "main session is checking project context"

      String.starts_with?(upcased, "PATH") ->
        "main session is choosing the next interview step"

      true ->
        clean
    end
  end

  # The shared conversation tail, color-coded by speaker so the dialectic
  # reads at a glance: MCP (the question generator) amber, MAIN (the
  # answerer/main session's resolved turn) green, YOU (your judgment) bold.
  # `drop_trailing_mcp?` hides the open question here when the picker below
  # already renders it. Returned as {text, style} rows the block paints
  # verbatim (no '> ' / strong inference).
  @dialogue_tail 6

  @doc false
  @spec dialogue_rows(map(), boolean()) :: [{String.t(), atom()}]
  def dialogue_rows(result, drop_trailing_mcp?) do
    turns =
      result
      |> interview_state()
      |> then(&((&1 && Map.get(&1, :dialogue, [])) || []))
      |> Enum.reverse()

    turns =
      if drop_trailing_mcp? do
        case List.last(turns) do
          %{role: :mcp} -> Enum.drop(turns, -1)
          _other -> turns
        end
      else
        turns
      end

    turns
    |> Enum.take(-@dialogue_tail)
    |> Enum.map(&dialogue_row/1)
  end

  defp dialogue_row(%{role: role, text: text}) do
    {label, style} =
      case role do
        :mcp -> {"MCP ", :warn}
        :main -> {"MAIN", :ok}
        :user -> {"YOU ", :strong}
      end

    {label <> "  " <> flatten_line(text), style}
  end

  # The LEFT-block activity under a plain question: a single animated line
  # carrying only the latest *clean* router trace — never the raw streamed
  # model text — so the main session's work is visible without leaking the
  # ASK_USER directive protocol. Public for snapshot tests.
  @doc false
  @spec interview_working_lines(map(), integer()) :: [String.t()]
  def interview_working_lines(result, tick) do
    iv = interview_state(result)
    trace = if iv, do: List.first(Map.get(iv, :router, [])), else: nil

    if paused?(result) or (iv && Map.get(iv, :complete) && is_nil(trace)) do
      []
    else
      [working_line(tick, trace)]
    end
  end

  # The active question's selection block: header (with "i/n" only when
  # multi), the question text, then each option with a ">" cursor on the
  # highlighted row. Public (snapshot tests) and deterministic for a given
  # detection + nav; [] when there is nothing to render.
  @doc false
  @spec wonder_picker_lines(map(), map() | nil) :: [String.t()]
  def wonder_picker_lines(detection, nav) do
    questions = wonder_questions(detection)
    n = length(questions)

    cond do
      n == 0 ->
        []

      Map.get(nav || %{}, :review?, false) ->
        wonder_review_lines(questions, nav)

      true ->
        qi = clamp_index(nav_qidx(nav), n)
        q = Enum.at(questions, qi)
        cursor = if multi_select?(q), do: nav_cursor(nav, qi), else: nav_pick(nav, qi)
        wonder_block_lines(q, qi, n, cursor, nav_multi_pick(nav, qi))
    end
  end

  defp wonder_review_lines(questions, nav) do
    total = length(questions)

    review_rows =
      questions
      |> Enum.with_index()
      |> Enum.flat_map(fn {q, qi} ->
        answer = review_answer_label(q, nav, qi)
        ["[#{qi + 1}/#{total}] #{md_text(Map.get(q, :header, "Question"))}", "  #{answer}"]
      end)

    [
      "Review answers before submit",
      "Enter confirms all selections, Esc returns to main session"
      | review_rows
    ]
  end

  defp review_answer_label(q, nav, qi) do
    options = Map.get(q, :options, [])

    if multi_select?(q) do
      nav_multi_pick(nav, qi)
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.map_join(", ", &option_label(options, &1))
      |> case do
        "" -> "No options selected"
        labels -> labels
      end
    else
      option_label(options, nav_pick(nav, qi))
    end
  end

  defp option_label(options, index) do
    options
    |> Enum.at(index)
    |> case do
      %{} = opt -> md_text(Map.get(opt, :label, "Option #{index + 1}"))
      _none -> "Free answer"
    end
  end

  defp wonder_qcount(detection), do: detection |> wonder_questions() |> length()

  # The active question's block: a header (with "i/n" only when multi), the
  # question text, then each option with a ">" cursor on the highlighted row
  # (draw_interview_block paints the ">"-led line in accent).
  defp wonder_block_lines(q, qi, n, cursor, multi_picks) do
    progress =
      if n > 1 do
        0..(n - 1)
        |> Enum.map_join("", fn idx -> if idx == qi, do: "*", else: "." end)
        |> then(&"  [#{&1}]")
      else
        ""
      end

    header =
      if n > 1,
        do: "Question #{qi + 1}/#{n}#{progress}  ·  #{md_text(Map.get(q, :header, ""))}",
        else: md_text(Map.get(q, :header, ""))

    opt_lines =
      q
      |> Map.get(:options, [])
      |> Enum.with_index()
      |> Enum.map(fn {opt, oi} ->
        row_cursor = if oi == cursor, do: ">", else: " "
        label = md_text(Map.get(opt, :label, ""))
        desc = md_text(Map.get(opt, :description, ""))

        marker =
          if multi_select?(q),
            do: "#{if(MapSet.member?(multi_picks, oi), do: "[x]", else: "[ ]")} [#{oi + 1}]",
            else: "[#{oi + 1}]"

        "#{row_cursor}#{row_cursor} #{marker} #{label} - #{desc}"
      end)

    free_row_cursor = if cursor == length(opt_lines), do: ">", else: " "
    free_row = "#{free_row_cursor}#{free_row_cursor} [Free answer] type below, then Enter"

    [header, md_text(Map.get(q, :question, "")) | opt_lines ++ [free_row]]
  end

  defp wonder_questions(detection) do
    case detection do
      %{request: %{questions: questions}} when is_list(questions) -> questions
      _other -> []
    end
  end

  defp nav_qidx(%{qidx: qidx}) when is_integer(qidx), do: qidx
  defp nav_qidx(_nav), do: 0

  defp nav_cursor(%{cursors: cursors}, qi) when is_map(cursors), do: Map.get(cursors, qi, 0)
  defp nav_cursor(nav, qi), do: nav_pick(nav, qi)

  defp nav_pick(%{picks: picks}, qi) when is_map(picks), do: Map.get(picks, qi, 0)
  defp nav_pick(_nav, _qi), do: 0

  defp nav_multi_pick(%{picks: picks}, qi) when is_map(picks) do
    case Map.get(picks, qi) do
      %MapSet{} = set -> set
      idx when is_integer(idx) -> MapSet.new([idx])
      _other -> MapSet.new()
    end
  end

  defp nav_multi_pick(_nav, _qi), do: MapSet.new()

  # Initializes / carries the selection cursor for the live checkpoint and
  # resets it when a new checkpoint (different request_id) arrives. Returns the
  # nav for the renderer; nil clears it when no checkpoint is pending.
  defp sync_wonder_nav(state, result) do
    case wonder_detection(result) do
      nil ->
        put_wonder_nav(state, nil)
        nil

      detection ->
        req_id = wonder_req_id(detection)
        nav = wonder_nav(state)

        nav =
          if is_map(nav) and Map.get(nav, :req_id) == req_id do
            nav
          else
            %{
              req_id: req_id,
              qidx: 0,
              cursors: default_cursors(detection),
              picks: default_picks(detection)
            }
          end

        put_wonder_nav(state, nav)
        nav
    end
  rescue
    _exception -> nil
  end

  defp wonder_req_id(detection) do
    case Map.get(detection, :request_id) do
      id when is_binary(id) and id != "" -> id
      _none -> "wt-" <> Integer.to_string(:erlang.phash2(wonder_questions(detection)))
    end
  end

  # Default highlight per question = its recommended option, else the first.
  defp default_picks(detection) do
    detection
    |> wonder_questions()
    |> Enum.with_index()
    |> Map.new(fn {q, qi} ->
      opts = Map.get(q, :options, [])
      idx = Enum.find_index(opts, &Map.get(&1, :recommended?, false)) || 0
      if multi_select?(q), do: {qi, MapSet.new([idx])}, else: {qi, idx}
    end)
  end

  defp default_cursors(detection) do
    detection
    |> wonder_questions()
    |> Enum.with_index()
    |> Enum.filter(fn {q, _qi} -> multi_select?(q) end)
    |> Map.new(fn {_q, qi} -> {qi, 0} end)
  end

  defp multi_select?(question) when is_map(question) do
    Map.get(question, :multi_select?, false) == true or
      Map.get(question, "multi_select", false) == true or
      Map.get(question, "multiSelect", false) == true
  end

  defp multi_select?(_question), do: false

  # While the session is live but no question is on the wire, the block is a
  # calm presence marker — replies still go to the main session (the block
  # does not capture keys), and it stays until the interview ends.
  defp interview_session_hint(result) do
    if paused?(result),
      do: "paused   type to talk to main   /answer <answer> submits to interview",
      else: "running   the main session is handling this   stays until it ends"
  end

  defp wonder_marker(result) do
    if paused?(result), do: "INTERVIEW (paused)", else: "INTERVIEW"
  end

  defp wonder_hint(result) do
    cond do
      paused?(result) -> "type to talk to main session   answers resume the interview"
      wonder_active?(result) -> "1-9 select   type free answer   /cancel decline   Esc pause"
      true -> "type your answer + Enter   Esc pause"
    end
  end

  defp wonder_pick_hint(result, qcount) do
    cond do
      paused?(result) ->
        "type to talk to main   /answer <answer> submits to interview"

      qcount > 1 ->
        "Up/Dn pick   Tab next question   Free answer row   Enter submit all   Esc pause"

      true ->
        "Up/Dn pick   1-9 shortcut   Free answer row   Enter submit   Esc pause"
    end
  end

  # Right-column section: MCP-internal only — what the interview engine puts
  # on the wire (ambiguity score, breakdown, milestone, seed-ready, server
  # status, session). The answerer/router reasoning is the MAIN SESSION's
  # work and lives in the LEFT block (`block_reasoning_tail/1`), never here.
  # Public for snapshot tests.
  @doc false
  def interview_reasoning_lines(result, tick \\ nil) do
    case interview_state(result) do
      %{} = iv ->
        [
          status_line(iv, tick, paused?(result)),
          mcp_reasoning_lines(iv),
          fallback_reasoning_lines(iv),
          complete_line(iv)
        ]
        |> List.flatten()
        |> Enum.reject(&is_nil/1)

      _none ->
        []
    end
  end

  defp mcp_reasoning_lines(%{mcp_reasoning: lines}) when is_list(lines) do
    lines
    |> Enum.map(&flatten_line/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp mcp_reasoning_lines(_iv), do: []

  defp fallback_reasoning_lines(%{mcp_reasoning: lines}) when is_list(lines) and lines != [],
    do: []

  defp fallback_reasoning_lines(iv) do
    [
      session_line(iv),
      ambiguity_line(iv),
      milestone_line(iv),
      seed_ready_line(iv)
    ] ++ breakdown_lines(iv)
  end

  # MCP-internal status the operator asked to see: when the question
  # generator is down (e.g. backend 502) ourocode says so explicitly
  # instead of silently stalling, with the resumable session id.
  defp status_line(_iv, _tick, true), do: "phase paused - discussing with main session"

  defp status_line(%{waiting: true, status: s}, tick, false) when is_binary(s) and s != "" do
    label =
      case String.downcase(s) do
        "waiting for mcp interview question" ->
          "phase received - MCP is preparing the interview question"

        "waiting for mcp follow-up question" ->
          "phase routing - MCP is preparing the next question"

        "waiting for your answer" ->
          "phase waiting - waiting for your answer"

        _other ->
          s
      end

    if is_integer(tick), do: spin(tick) <> " " <> label, else: label
  end

  defp status_line(%{status: s}, _tick, _paused) when is_binary(s) and s != "",
    do: "phase active - " <> s

  defp status_line(_iv, _tick, _paused), do: nil

  defp session_line(%{session_id: s}) when is_binary(s) and s != "",
    do: "session " <> s

  defp session_line(_iv), do: nil

  defp ambiguity_line(%{ambiguity: a}) when is_float(a) or is_integer(a),
    do: "ambiguity #{:erlang.float_to_binary(a / 1, decimals: 2)}"

  defp ambiguity_line(_iv), do: nil

  defp milestone_line(%{milestone: m}) when is_binary(m) and m != "", do: "milestone " <> m
  defp milestone_line(_iv), do: nil

  defp seed_ready_line(%{seed_ready: true}), do: "seed-ready: yes"
  defp seed_ready_line(%{seed_ready: false}), do: "seed-ready: no"
  defp seed_ready_line(_iv), do: nil

  defp breakdown_lines(%{breakdown: b}) when is_map(b) do
    Enum.map(b, fn {k, v} -> "#{k}: #{inspect(v)}" end)
  end

  defp breakdown_lines(_iv), do: []

  defp complete_line(%{complete: reason}) when not is_nil(reason),
    do: "interview complete: #{reason}"

  defp complete_line(_iv), do: nil

  defp flatten_line(text) do
    text
    |> md_text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp md_text(text) do
    text
    |> to_string()
    |> String.replace(~r/(\*\*|__)(.*?)\1/s, "\\2")
    |> String.replace(~r/(\*|_)(.*?)\1/s, "\\2")
    |> String.replace(~r/`([^`]+)`/, "\\1")
    |> String.replace(~r/^\s{0,3}\#{1,6}\s+/m, "")
    |> String.replace(~r/\[([^\]]+)\]\([^)]+\)/, "\\1")
    |> strip_unstable_glyphs()
    |> String.trim()
  end

  defp strip_unstable_glyphs(text) do
    text
    |> String.replace(~r/[\x{FFFD}\x{FE0E}\x{FE0F}\x{200D}]/u, "")
    |> String.replace(~r/[\x{1F000}-\x{1FAFF}]/u, "")
    |> String.replace(~r/\s+/, " ")
  end

  defp view_opts(state) do
    mode = get_mode(state)

    %{
      mode: mode,
      login: login_state(state),
      streaming: streaming?(state),
      key_help: key_help?(state),
      tick: tick(state),
      scroll: scroll_off(state),
      pidx: pidx(state),
      auth: auth_label(state),
      notifications: notifications(state),
      ooo_commands:
        if mode == :normal and ooo_prompt?(buffer(state)) do
          cached_ooo_commands(state)
        else
          nil
        end,
      palette:
        if mode == :palette do
          entries = Palette.filter(Palette.entries(), buffer(state))
          %{entries: entries, index: Palette.clamp(pidx(state), length(entries))}
        else
          nil
        end,
      model:
        if mode == :model do
          models = Catalog.selectable(Catalog.list())
          %{models: models, index: clamp_index(pidx(state), length(models))}
        else
          nil
        end,
      file_mentions: file_mention_suggestions(state, mode, false)
    }
  end

  # Modular wrap: pidx grows unbounded as arrows are pressed, so it must map
  # continuously onto 0..n-1 (a plain clamp froze the selection after one
  # full cycle).
  defp clamp_index(_i, 0), do: 0
  defp clamp_index(i, n), do: Integer.mod(i, n)

  @left 2
  @body 4
  @pulse [".", "o", "O", "o"]

  defp compose(columns, rows, sections, activity, prompt_buffer, opts) do
    width = max(columns, @min_width)
    height = max(rows, @min_height)
    kv = status_fields(sections)
    mode = Map.get(opts, :mode, :normal)
    login = Map.get(opts, :login)
    palette = Map.get(opts, :palette)
    model_overlay = Map.get(opts, :model)
    interview_block = Map.get(opts, :interview_block)
    wonder_focus = Map.get(opts, :wonder_focus, false)
    reasoning = Map.get(opts, :interview_reasoning, [])
    activity = maybe_focus_paused_interview_activity(activity, opts)
    interview_present? = match?({_marker, _lines, _hint}, interview_block)
    interview_owns_left? = interview_present? and not Map.get(opts, :interview_paused, false)
    body_activity = if interview_owns_left?, do: [], else: activity
    palette = maybe_add_paused_answer_palette(palette, prompt_buffer, opts)
    file_mentions = Map.get(opts, :file_mentions, [])
    file_mention_index = Palette.clamp(Map.get(opts, :pidx, 0), length(file_mentions))
    resource_mentions = resource_mention_suggestions(prompt_buffer, mode, wonder_focus, opts)
    resource_mention_index = Palette.clamp(Map.get(opts, :pidx, 0), length(resource_mentions))

    ooo_suggestions =
      ooo_suggestions(prompt_buffer, mode, wonder_focus, Map.get(opts, :ooo_commands))

    ooo_index = Palette.clamp(Map.get(opts, :pidx, 0), length(ooo_suggestions))

    composer_rule = height - 3
    transcript_top = 4
    transcript_bottom = composer_rule - 2

    screen =
      Screen.new(width, height)
      |> draw_header(width, kv, opts)

    scroll = Map.get(opts, :scroll, 0)
    split? = mcp_active?(sections) or reasoning != []

    # A live picker is an intentional checkpoint: mute the rest of the body
    # and let the decision UI own the available space so it cannot be missed.
    screen =
      if wonder_focus and interview_present? do
        draw_wonder_focus(
          screen,
          width,
          transcript_top,
          transcript_bottom,
          interview_block,
          prompt_buffer
        )
      else
        screen
      end

    # A pending interview pins a prominent block at the top of the left column
    # (not a modal). In split mode it consumes only the left column; the right
    # telemetry panel keeps its full height so it does not jump when questions
    # arrive.
    {screen, body_top} =
      case {wonder_focus, interview_block} do
        {true, {_marker, _lines, _hint}} ->
          {screen, transcript_top}

        {_focus, nil} ->
          {screen, transcript_top}

        {_focus, {marker, lines, hint}} ->
          left_w = split_left_w(width)
          block_w = if reasoning == [] and not mcp_active?(sections), do: width, else: left_w
          max_rows = max(transcript_bottom - transcript_top - 1, 1)

          {screen, used} =
            draw_interview_block(screen, transcript_top, block_w, marker, lines, hint, max_rows)

          {screen, transcript_top + used + 1}
      end

    screen =
      cond do
        wonder_focus ->
          screen

        login ->
          draw_login_card(screen, width, transcript_top, transcript_bottom, login)

        palette || model_overlay ->
          draw_transcript(
            screen,
            width,
            body_top,
            transcript_bottom,
            body_activity,
            false,
            scroll
          )

        split? ->
          draw_runtime_split(
            screen,
            width,
            if(interview_owns_left?, do: transcript_bottom + 1, else: body_top),
            transcript_top,
            transcript_bottom,
            body_activity,
            sections,
            scroll,
            reasoning
          )

        interview_owns_left? ->
          screen

        true ->
          draw_transcript(screen, width, body_top, transcript_bottom, body_activity, true, scroll)
      end

    screen =
      cond do
        palette ->
          draw_palette(screen, width, transcript_bottom, palette)

        model_overlay ->
          draw_model_overlay(screen, width, transcript_bottom, model_overlay)

        resource_mentions != [] ->
          draw_resource_mentions(
            screen,
            width,
            transcript_bottom,
            resource_mentions,
            resource_mention_index
          )

        file_mentions != [] ->
          draw_file_mentions(screen, width, transcript_bottom, file_mentions, file_mention_index)

        ooo_suggestions != [] ->
          draw_ooo_suggestions(screen, width, transcript_bottom, ooo_suggestions, ooo_index)

        Map.get(opts, :key_help, false) ->
          draw_key_help(screen, width, transcript_bottom, mode, opts)

        true ->
          screen
      end

    screen
    |> draw_composer(width, composer_rule, prompt_buffer, mode, opts)
    |> draw_status_bar(width, height - 1, kv, sections, mode, opts)
  end

  defp maybe_focus_paused_interview_activity(activity, %{interview_paused: true}) do
    paused_interview_discussion_activity(activity)
  end

  defp maybe_focus_paused_interview_activity(activity, _opts), do: activity

  defp paused_interview_discussion_activity(activity) when activity in [nil, []], do: []

  defp paused_interview_discussion_activity(activity) do
    activity
    |> Enum.reduce({[], nil}, fn line, {kept, role} ->
      trimmed = String.trim(line)

      cond do
        paused_interview_noise?(trimmed) ->
          {kept, nil}

        String.starts_with?(trimmed, "you> ") or String.starts_with?(trimmed, "> ") ->
          {[line | kept], :user}

        String.starts_with?(trimmed, "ourocode> ") ->
          {[line | kept], :assistant}

        role in [:user, :assistant] and trimmed != "" and not system_line?(trimmed) ->
          {[line | kept], role}

        true ->
          {kept, nil}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp paused_interview_noise?(trimmed) when is_binary(trimmed) do
    downcased = String.downcase(trimmed)

    trimmed in ["", "empty", "-- empty"] or
      String.starts_with?(trimmed, "-- ") or
      String.contains?(downcased, [
        "[workflow-starting]",
        "queued task ",
        "interview paused",
        "workflow",
        "dispatching_input"
      ])
  end

  defp paused_interview_noise?(_trimmed), do: false

  defp maybe_add_paused_answer_palette(%{entries: entries} = palette, prompt_buffer, opts) do
    if Map.get(opts, :interview_paused, false) do
      answer_entries =
        if paused_answer_query?(prompt_buffer),
          do: [paused_answer_entry()],
          else: Palette.filter([paused_answer_entry()], prompt_buffer)

      entries = answer_entries ++ Enum.reject(entries, &(&1.slash == "/answer"))
      index = Palette.clamp(Map.get(opts, :pidx, Map.get(palette, :index, 0)), length(entries))
      %{palette | entries: entries, index: index}
    else
      palette
    end
  end

  defp maybe_add_paused_answer_palette(palette, _prompt_buffer, _opts), do: palette

  defp paused_answer_query?(prompt_buffer) when is_binary(prompt_buffer) do
    prompt_buffer
    |> String.trim_leading()
    |> String.downcase()
    |> then(&(&1 == "/answer" or String.starts_with?(&1, "/answer ")))
  end

  defp paused_answer_query?(_prompt_buffer), do: false

  defp paused_answer_entry do
    %{
      slash: "/answer",
      name: "answer",
      summary: "Use while paused: /answer <answer> submits to the interview.",
      category: :interaction,
      source: :runtime,
      availability: :ready,
      aliases: [],
      args: [%{name: "answer", required?: true, description: "Interview answer text"}]
    }
  end

  # Accent appears in exactly four places (wordmark, caret, selected palette
  # row, healthy/streaming dot). Everything else is neutral grey so the accent
  # stays rare and meaningful.
  defp draw_header(screen, width, kv, opts) do
    {dot, dot_style} = activity_dot(kv, opts)

    status_word =
      if Map.get(opts, :streaming), do: "thinking", else: Map.get(kv, "status", "starting")

    {auth_text, auth_style} = Map.get(opts, :auth, {"no model  -  /model", :dim})
    auth_col = max(width - String.length(auth_text) - @left, @left)
    status_col = max(auth_col - String.length(status_word) - 4, @left + 20)

    screen
    |> Screen.put_text(@left, 1, "ourocode", :brand)
    |> Screen.put_text(@left + 9, 1, "agent", :dim)
    |> Screen.put_text(status_col, 1, dot, dot_style)
    |> Screen.put_text(status_col + 2, 1, status_word, :dim)
    |> Screen.put_text(auth_col, 1, auth_text, auth_style)
    |> Screen.put_text(@left, 2, "terminal-native interactive baseline", :dim)
  end

  defp activity_dot(kv, opts) do
    if Map.get(opts, :streaming) do
      frame = Enum.at(@pulse, rem(Map.get(opts, :tick, 0), length(@pulse)))
      {frame, :accent}
    else
      health_indicator(kv)
    end
  end

  # R1: turns render as scannable blocks - a dim role label, a coloured left
  # rail, and an indented body - instead of a flat log. This is the structure
  # a conversation needs and the one thing that makes it feel designed.
  defp draw_transcript(
         screen,
         width,
         top,
         bottom,
         activity,
         show_empty_hint,
         scroll,
         clip_override \\ nil
       ) do
    region = max(bottom - top + 1, 1)
    render_rows = transcript_render_rows(activity)

    cond do
      render_rows == [] and not show_empty_hint ->
        screen

      render_rows == [] ->
        mid = top + div(region, 2)

        screen
        |> center(mid - 1, width, "ourocode", :brand)
        |> center(mid + 1, width, "Sign in with  /login,  then ask anything", :dim)
        |> center(mid + 2, width, "or type  /  to browse commands", :muted)

      true ->
        # `scroll` rows back from the tail; clamped so it can never run past
        # the buffered history (full scroll-back, no 8-line truncation).
        total = length(render_rows)
        offset = min(max(scroll, 0), max(total - region, 0))
        slice_end = total - offset
        slice_start = max(slice_end - region, 0)
        visible = Enum.slice(render_rows, slice_start, slice_end - slice_start)
        start = bottom - length(visible) + 1

        visible
        |> Enum.with_index()
        |> Enum.reduce(screen, fn {row, i}, acc ->
          y = start + i

          acc =
            case row.rail do
              nil -> acc
              ch -> Screen.put_text(acc, @left, y, ch, row.rail_style)
            end

          clip_w = clip_override || width - @body - @left
          Screen.put_text(acc, @body, y, clip(row.text, clip_w), row.text_style)
        end)
    end
  end

  defp transcript_render_rows(activity) when activity in [nil, []], do: []

  defp transcript_render_rows(activity) do
    activity
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reduce({[], nil}, &fold_transcript_line/2)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == :sep))
    |> Enum.map(&render_row/1)
  end

  defp fold_transcript_line(line, {rows, role}) do
    cond do
      # A leaked SSoT block (e.g. parent-pane workflow feedback) borrows the
      # +--/| frame syntax meant for the status channel, not the transcript.
      # Swallow the frame; surface only its inner content as clean system
      # notes so no box-art fragment ever reaches the conversation.
      String.starts_with?(line, "+-- ") ->
        {rows, :ssot}

      role == :ssot and line == "+--" ->
        {rows, nil}

      role == :ssot ->
        case strip_prefix(line, "| ") do
          nil -> {rows, :ssot}
          inner -> {[{:system, humanize(inner)}, :sep | rows], :ssot}
        end

      rest = strip_prefix(line, "you> ") ->
        push_block(rows, :user, "YOU", rest)

      rest = strip_prefix(line, "ourocode> ") ->
        push_block(rows, :assistant, "OUROCODE", rest)

      rest = strip_prefix(line, "> ") ->
        push_block(rows, :user, "YOU", rest)

      system_line?(line) ->
        {[{:system, line}, :sep | rows], nil}

      line == "" ->
        {rows, role}

      role in [:user, :assistant] ->
        {[{{:body, role}, line} | rows], role}

      true ->
        {[{:system, line}, :sep | rows], nil}
    end
  end

  defp push_block(rows, role, label, first) do
    rows = [{{:body, role}, first}, {{:label, role}, label}, :sep | rows]
    {rows, role}
  end

  defp strip_prefix(line, prefix) do
    if String.starts_with?(line, prefix),
      do: String.replace_prefix(line, prefix, ""),
      else: nil
  end

  defp system_line?(line) do
    String.starts_with?(line, [
      "queued ",
      "Signed ",
      "Sign in",
      "Login",
      "Not connected",
      "No model",
      "Model error",
      "Connect ChatGPT",
      "model:"
    ]) or String.contains?(line, ["error", "failed"])
  end

  defp render_row(:sep), do: %{rail: nil, rail_style: :text, text: "", text_style: :text}

  defp render_row({{:label, _role}, text}),
    do: %{rail: nil, rail_style: :text, text: text, text_style: :label}

  defp render_row({{:body, :user}, text}),
    do: %{rail: "|", rail_style: :accent, text: text, text_style: :strong}

  defp render_row({{:body, :assistant}, text}),
    do: %{rail: "|", rail_style: :dim, text: text, text_style: :text}

  # System notes (model switches, sign-in status, warnings) are deliberately
  # set apart from conversation turns: no role label, no rail, dimmer, and a
  # `--` lead so the eye never confuses them with what the model said.
  defp render_row({:system, text}),
    do: %{rail: nil, rail_style: :text, text: "-- " <> humanize(text), text_style: :muted}

  defp draw_wonder_focus(screen, width, top, bottom, {marker, lines, hint}, prompt_buffer) do
    panel_x = @left
    panel_w = max(width - 2 * @left, 1)
    panel_h = max(bottom - top + 1, 1)
    inner_x = panel_x + 2
    inner_w = max(panel_w - 4, 1)
    max_content = max(panel_h - 5, 1)

    rows =
      lines
      |> Enum.flat_map(&wrap_focus_line(&1, inner_w))
      |> Enum.take(max_content)

    input =
      case String.trim(prompt_buffer) do
        "" -> "Free answer: type here, then Enter"
        text -> "Free answer: " <> text
      end

    hint = "j/k or Up/Dn select   h/l or Left/Right question   Esc main session   " <> hint

    screen =
      screen
      |> Screen.fill_rect(0, top, width, panel_h, :p_fill)
      |> Screen.put_text(inner_x, top + 1, clip(marker, inner_w), :p_title)

    screen =
      rows
      |> Enum.with_index(2)
      |> Enum.reduce(screen, fn {{text, style}, offset}, acc ->
        Screen.put_text(acc, inner_x, top + offset, clip(text, inner_w), style)
      end)

    hint_top = bottom - 2

    screen
    |> Screen.put_text(inner_x, hint_top, clip(input, inner_w), :p_accent)
    |> Screen.put_text(inner_x, hint_top + 1, clip(hint, inner_w), :p_muted)
  end

  defp wrap_focus_line(line, inner) when is_binary(line) do
    style =
      cond do
        String.starts_with?(line, ">> ") -> :p_accent
        String.starts_with?(line, "   [") -> :p_dim
        true -> :p_title
      end

    wrap_styled(line, style, inner)
  end

  # A focal, centred card for the login moment so the device code is the one
  # thing the eye lands on.
  defp draw_login_card(screen, width, top, bottom, login) do
    card_w = min(54, width - 2 * @left)
    card_h = 7
    x = div(width - card_w, 2)
    y = top + max(div(bottom - top + 1 - card_h, 2), 0)
    code = Map.get(login, :code, "------")
    url = Map.get(login, :url, "")

    screen
    |> Screen.box(x, y, card_w, card_h, "Connect ChatGPT", :accent)
    |> center(y + 2, width, url, :dim)
    |> center(y + 4, width, code, :brand)
    |> center(y + card_h, width, "waiting for approval - Ctrl-C to cancel", :muted)
  end

  @overlay_rows 8

  # Slides a window over the full list so the selection moves through every
  # item instead of wrapping inside the first eight rows (which made long
  # lists look frozen once you reached the visible end).
  defp window(items, _index) when items == [], do: {0, []}

  defp window(items, index) do
    total = length(items)
    idx = max(min(index, total - 1), 0)

    offset =
      cond do
        total <= @overlay_rows -> 0
        idx < @overlay_rows -> 0
        true -> min(idx - @overlay_rows + 1, total - @overlay_rows)
      end

    {offset, Enum.slice(items, offset, @overlay_rows) |> Enum.with_index(offset)}
  end

  defp draw_overlay(screen, width, anchor_bottom, title, items, index, row_fun) do
    {_offset, windowed} = window(items, index)
    box_w = width - 2 * @left
    inner = box_w - 2
    box_h = max(length(windowed), 1) + 2
    y = anchor_bottom - box_h + 1

    screen = Screen.box(screen, @left, y, box_w, box_h, title, :border)

    if windowed == [] do
      Screen.put_text(screen, @left + 1, y + 1, pad("  nothing here", inner), :dim)
    else
      windowed
      |> Enum.with_index()
      |> Enum.reduce(screen, fn {{item, abs_i}, row}, acc ->
        selected? = abs_i == index
        marker = if selected?, do: ">", else: " "
        line = " #{marker} #{row_fun.(item)}"
        style = if selected?, do: :accent, else: :dim
        Screen.put_text(acc, @left + 1, y + 1 + row, pad(line, inner), style)
      end)
    end
  end

  defp draw_palette(screen, width, anchor_bottom, %{entries: entries, index: index}) do
    screen =
      draw_overlay(
        screen,
        width,
        anchor_bottom,
        "commands  (#{length(entries)})",
        entries,
        index,
        fn e ->
          tag = if e.availability == :stub, do: "  (stub)", else: ""
          "#{String.pad_trailing(e.slash, 12)} #{e.summary}#{tag}"
        end
      )

    draw_palette_detail(screen, width, anchor_bottom, entries, index)
  end

  defp draw_palette_detail(screen, width, anchor_bottom, entries, index) do
    case Palette.selected(entries, index) do
      nil ->
        screen

      entry ->
        visible_rows = max(min(length(entries), @overlay_rows), 1)
        box_w = width - 2 * @left
        inner = box_w - 2
        rows = palette_detail_rows(entry, inner)
        y = anchor_bottom - visible_rows - 2 - length(rows)

        rows
        |> Enum.with_index()
        |> Enum.reduce(screen, fn {row, offset}, acc ->
          Screen.put_text(acc, @left + 1, y + offset, pad(row, inner), :muted)
        end)
    end
  end

  defp palette_detail_rows(entry, inner) do
    semantics =
      entry
      |> palette_capability_registry()
      |> CapabilityGraph.build()
      |> Map.fetch!(:capabilities)
      |> List.first()
      |> Map.fetch!(:semantics)

    aliases =
      case Map.get(entry, :aliases, []) do
        [] -> "none"
        values -> Enum.join(values, ", ")
      end

    args =
      entry
      |> Map.get(:args, [])
      |> Enum.map(fn arg ->
        suffix = if Map.get(arg, :required?), do: "!", else: "?"
        "#{Map.get(arg, :name, "arg")}#{suffix}"
      end)
      |> case do
        [] -> "none"
        values -> Enum.join(values, ", ")
      end

    [
      "selected #{entry.slash}  source=#{entry.source} trust=#{palette_trust_tier(entry)} category=#{entry.category} availability=#{entry.availability}",
      "capability #{semantics.scope}/#{semantics.mutation_class}/#{semantics.approval_class}  aliases=#{aliases}  args=#{args}"
    ]
    |> Enum.map(&Screen.truncate(&1, inner))
  end

  defp palette_trust_tier(%{source: :builtin}), do: "builtin"
  defp palette_trust_tier(%{source: :bundled_skill}), do: "bundled"
  defp palette_trust_tier(%{source: :local}), do: "local"
  defp palette_trust_tier(%{source: :plugin}), do: "plugin"
  defp palette_trust_tier(%{source: :mcp}), do: "mcp"
  defp palette_trust_tier(%{source: :dynamic_skill}), do: "dynamic"
  defp palette_trust_tier(_entry), do: "unknown"

  defp palette_capability_registry(entry) do
    %{
      ordered: [
        %{
          id: "#{entry.source}:#{entry.slash}",
          name: entry.name,
          slash: entry.slash,
          summary: entry.summary,
          source: entry.source,
          source_id: to_string(entry.source),
          category: entry.category,
          run_spec: %{}
        }
      ]
    }
  end

  defp draw_model_overlay(screen, width, anchor_bottom, %{models: models, index: index}) do
    draw_overlay(screen, width, anchor_bottom, "model", models, index, fn m ->
      status = if Model.ready?(m), do: "ready", else: "sign in required"
      "#{String.pad_trailing(m.label, 20)} #{status}"
    end)
  end

  defp draw_ooo_suggestions(screen, width, anchor_bottom, suggestions, index) do
    draw_overlay(screen, width, anchor_bottom, "ooo commands", suggestions, index, fn {command,
                                                                                       summary} ->
      "#{String.pad_trailing(command, 18)} #{summary}"
    end)
  end

  defp draw_file_mentions(screen, width, anchor_bottom, suggestions, index) do
    draw_overlay(screen, width, anchor_bottom, "@ files", suggestions, index, fn {path, label} ->
      "#{String.pad_trailing("@" <> path, 36)} #{label}"
    end)
  end

  defp draw_resource_mentions(screen, width, anchor_bottom, suggestions, index) do
    draw_overlay(screen, width, anchor_bottom, "@ mcp resources", suggestions, index, fn {uri,
                                                                                          label} ->
      "#{String.pad_trailing("@mcp:" <> uri, 40)} #{label}"
    end)
  end

  defp resource_mention_suggestions(prompt_buffer, :normal, false, opts) do
    case active_resource_mention_query(prompt_buffer) do
      nil ->
        []

      query ->
        opts
        |> Map.get(:resource_mentions, [])
        |> Enum.map(fn {uri, label} -> {uri, {uri, label}} end)
        |> Ourocode.Terminal.Fuzzy.rank(query, limit: 8)
    end
  end

  defp resource_mention_suggestions(_prompt_buffer, _mode, _wonder_focus, _opts), do: []

  defp active_resource_mention_query(prompt_buffer) when is_binary(prompt_buffer) do
    case Regex.run(~r/(?:^|\s)@mcp:([^\s@]*)$/u, prompt_buffer) do
      [_, query] -> query
      _none -> nil
    end
  end

  defp draw_key_help(screen, width, anchor_bottom, mode, opts) do
    rows =
      case {mode, Map.get(opts, :wonder_focus, false), Map.get(opts, :interview_paused, false)} do
        {_mode, true, _paused} ->
          [
            {"Up/Dn j/k", "move option"},
            {"Left/Right h/l", "move question"},
            {"Space", "toggle multi-select"},
            {"Enter", "submit or review"},
            {"Esc", "pause to main session"}
          ]

        {_mode, _focus, true} ->
          [
            {"/answer <text>", "submit to interview"},
            {"type normally", "discuss with main session"},
            {"Ctrl-G", "hide this help"}
          ]

        {:palette, _focus, _paused} ->
          [{"Up/Dn", "move"}, {"Enter", "run"}, {"Esc", "close"}, {"Ctrl-G", "hide help"}]

        _other ->
          [
            {"/", "commands"},
            {"@", "file mentions"},
            {"Up/Ctrl-P", "history"},
            {"Ctrl-A/E", "line start/end"},
            {"Ctrl-G", "hide help"}
          ]
      end

    draw_overlay(screen, width, anchor_bottom, "keys", rows, 0, fn {key, desc} ->
      "#{String.pad_trailing(key, 18)} #{desc}"
    end)
  end

  @ooo_fallback_commands [
    {"ooo interview", "clarify requirements through a Socratic interview"},
    {"ooo pm", "shape product requirements through a PM interview"},
    {"ooo auto", "interview, generate a Seed, and execute automatically"},
    {"ooo clarify", "turn vague requirements into a concrete direction"},
    {"ooo seed", "generate a validated Seed from the current interview"},
    {"ooo run", "execute a Seed specification"},
    {"ooo evolve", "run one evolutionary generation"},
    {"ooo ralph", "run an iterative Ralph loop"},
    {"ooo qa", "evaluate an artifact against a quality bar"},
    {"ooo evaluate", "run the three-stage execution evaluator"},
    {"ooo status", "inspect session status and drift"},
    {"ooo cancel", "cancel a stuck or orphaned execution"},
    {"ooo brownfield", "scan and manage repository context"},
    {"ooo publish", "publish Seed requirements as GitHub issues"},
    {"ooo resume-session", "list or resume in-flight Ouroboros sessions"},
    {"ooo help", "show Ouroboros commands and agents"},
    {"ooo tutorial", "learn Ouroboros hands-on"},
    {"ooo update", "check for Ouroboros updates"}
  ]

  @ooo_cache_ttl_ms 30_000

  defp ooo_suggestions(prompt_buffer, :normal, false, commands) do
    trimmed = String.trim_leading(prompt_buffer)
    commands = commands || @ooo_fallback_commands

    cond do
      trimmed == "ooo" ->
        commands

      String.starts_with?(trimmed, "ooo ") ->
        query =
          trimmed
          |> String.replace_prefix("ooo ", "")
          |> String.trim()
          |> String.downcase()

        commands
        |> Enum.map(fn {command, summary} -> {command, {command, summary}} end)
        |> Ourocode.Terminal.Fuzzy.rank(query, limit: 8)

      true ->
        []
    end
  end

  defp ooo_suggestions(_prompt_buffer, _mode, _wonder_focus, _commands), do: []

  defp ooo_prompt?(prompt_buffer) when is_binary(prompt_buffer) do
    trimmed = String.trim_leading(prompt_buffer)
    trimmed == "ooo" or String.starts_with?(trimmed, "ooo ")
  end

  defp ooo_prompt?(_prompt_buffer), do: false

  defp cached_ooo_commands(state) do
    now = System.monotonic_time(:millisecond)

    Agent.get_and_update(state, fn s ->
      fresh? =
        is_list(s.ooo_cache) and is_integer(Map.get(s, :ooo_cache_loaded_ms)) and
          now - s.ooo_cache_loaded_ms < @ooo_cache_ttl_ms

      commands = if fresh?, do: s.ooo_cache, else: build_ooo_commands()
      {commands, %{s | ooo_cache: commands, ooo_cache_loaded_ms: now}}
    end)
  end

  defp build_ooo_commands do
    registry_commands =
      case Registry.load() do
        {:ok, registry} ->
          registry
          |> Registry.entries()
          |> Enum.filter(&ooo_registry_entry?/1)
          |> Enum.map(&ooo_registry_command/1)

        _error ->
          []
      end

    usage = if test_run?(), do: %{}, else: PromptStore.command_usage()

    (@ooo_fallback_commands ++ registry_commands)
    |> Enum.uniq_by(fn {command, _summary} -> command end)
    |> rank_ooo_by_usage(usage)
  rescue
    _exception -> @ooo_fallback_commands
  end

  defp rank_ooo_by_usage(commands, usage) when is_map(usage) do
    commands
    |> Enum.with_index()
    |> Enum.sort_by(fn {{command, _summary}, index} -> {-Map.get(usage, command, 0), index} end)
    |> Enum.map(fn {command, _index} -> command end)
  end

  defp ooo_registry_entry?(entry) do
    entry.source in [:plugin, :dynamic_skill] or
      String.starts_with?(entry.name, "ouroboros") or
      entry.name in [
        "interview",
        "pm",
        "auto",
        "clarify",
        "seed",
        "run",
        "evolve",
        "ralph",
        "qa",
        "evaluate",
        "status",
        "cancel",
        "brownfield",
        "publish",
        "resume-session",
        "help",
        "tutorial",
        "update"
      ]
  end

  defp ooo_registry_command(entry) do
    name =
      entry.name
      |> String.replace_prefix("ouroboros-", "")
      |> String.replace_prefix("ouroboros_", "")

    {"ooo " <> name, entry.summary}
  end

  defp ooo_suggesting?(state) do
    prompt_buffer = buffer(state)

    ooo_prompt?(prompt_buffer) and
      ooo_suggestions(prompt_buffer, :normal, false, cached_ooo_commands(state)) != []
  end

  defp file_mention_suggestions(state, :normal, false) do
    case active_file_mention_query(buffer(state), cursor(state)) do
      nil ->
        []

      query ->
        state
        |> file_cache()
        |> Enum.map(fn path -> {path, {path, file_label(path)}} end)
        |> Ourocode.Terminal.Fuzzy.rank(query, limit: 8)
    end
  end

  defp file_mention_suggestions(_state, _mode, _wonder_focus), do: []

  defp file_mention_suggesting?(state) do
    file_mention_suggestions(state, get_mode(state), false) != []
  end

  defp insert_file_mention_choice(state) do
    suggestions = file_mention_suggestions(state, get_mode(state), false)
    clamped = Palette.clamp(pidx(state), length(suggestions))

    case Enum.at(suggestions, clamped) do
      {path, _label} ->
        Agent.update(state, fn s ->
          {buffer, cursor} = replace_active_file_mention(s.buffer, s.cursor, path)
          %{s | buffer: buffer, cursor: cursor}
        end)

      _none ->
        :ok
    end
  end

  defp replace_active_file_mention(buffer, cursor, path) do
    graphemes = String.graphemes(buffer)
    cursor = clamp_cursor(cursor, length(graphemes))
    {left, right} = Enum.split(graphemes, cursor)
    prefix = Enum.join(left)

    case Regex.run(~r/(^|\s)@([^\s@]*)$/u, prefix, return: :index) do
      [{start, _len}, {_sep_start, sep_len}, _query] ->
        before = binary_part(prefix, 0, start)
        sep = binary_part(prefix, start, sep_len)
        replacement = sep <> "@" <> path <> " "
        new_prefix = before <> replacement
        {new_prefix <> Enum.join(right), String.length(new_prefix)}

      _none ->
        text = "@" <> path <> " "
        {buffer <> text, String.length(buffer) + String.length(text)}
    end
  end

  @doc false
  def active_file_mention_query(prompt_buffer, cursor) when is_binary(prompt_buffer) do
    graphemes = String.graphemes(prompt_buffer)
    cursor = clamp_cursor(cursor, length(graphemes))
    prefix = graphemes |> Enum.take(cursor) |> Enum.join()

    case Regex.run(~r/(?:^|\s)@([^\s@]*)$/u, prefix) do
      [_, query] -> query
      _none -> nil
    end
  end

  defp file_label(path) do
    path
    |> Path.dirname()
    |> case do
      "." -> "project file"
      dir -> dir
    end
  end

  defp ooo_choice(prompt_buffer, index, state) do
    suggestions = ooo_suggestions(prompt_buffer, :normal, false, cached_ooo_commands(state))
    clamped = Palette.clamp(index, length(suggestions))

    case Enum.at(suggestions, clamped) do
      {command, _summary} -> command
      _none -> String.trim(prompt_buffer)
    end
  end

  # Pads (or clips) to an exact width so an overlay fully covers whatever it
  # is drawn on top of, leaving no trailing residue.
  defp pad(text, width) do
    t = Screen.truncate(text, width)
    t <> String.duplicate(" ", max(width - Screen.text_width(t), 0))
  end

  # R2: one quiet rule above a single caret line. No fax-style double rules.
  # The caret is the only accent in the lower region.
  defp draw_composer(screen, width, rule_row, prompt_buffer, mode, opts) do
    rule = String.duplicate("-", max(width - 2 * @left, 0))

    placeholder =
      cond do
        Map.get(opts, :interview_paused, false) ->
          "/answer <answer> submits to interview, or type normally to discuss with main session"

        Map.get(opts, :wonder_focus, false) ->
          "Free answer for this interview checkpoint, or Esc to talk to main session"

        mode == :palette ->
          "type to filter commands"

        true ->
          "Message ourocode, or  /  for commands"
      end

    {body_text, body_style} =
      if prompt_buffer == "",
        do: {placeholder, :placeholder},
        else: {prompt_buffer, :text}

    screen =
      screen
      |> Screen.put_text(@left, rule_row, rule, :border)
      |> Screen.put_text(@left, rule_row + 1, ">", :accent)

    put_composer_text(screen, @body, rule_row + 1, body_text, body_style, width - @body - @left)
  end

  defp put_composer_text(screen, x, y, text, :text, width) do
    clipped = clip(text, width)

    if String.starts_with?(String.trim_leading(clipped), "ooo") do
      leading = byte_size(clipped) - byte_size(String.trim_leading(clipped))
      prefix = binary_part(clipped, 0, leading)
      rest = binary_part(clipped, leading, byte_size(clipped) - leading)

      screen = Screen.put_text(screen, x, y, prefix, :text)
      token_w = Screen.text_width(prefix)

      screen
      |> Screen.put_text(x + token_w, y, "ooo", :brand)
      |> Screen.put_text(x + token_w + 3, y, String.replace_prefix(rest, "ooo", ""), :text)
    else
      Screen.put_text(screen, x, y, clipped, :text)
    end
  end

  defp put_composer_text(screen, x, y, text, style, width) do
    Screen.put_text(screen, x, y, clip(text, width), style)
  end

  # Conditional density: only surface what carries signal. Zeroes and idle
  # states stay hidden so the line reads at a glance instead of as a wall.
  defp draw_status_bar(screen, width, row, kv, sections, mode, opts) do
    transports =
      case Map.get(kv, "transports", "none") do
        "none" -> "offline"
        list -> list |> String.replace("streamable_http", "http") |> String.replace(",", " ")
      end

    queued = Map.get(kv, "queued", "0")
    hooks = Map.get(kv, "hooks", "idle")
    sessions = count_sessions(sections)
    plugins = count_plugins(sections)

    left =
      [Map.get(kv, "runtime", "?"), transports]
      |> maybe(sessions > 0, "#{sessions} sessions")
      |> maybe(plugins > 0, "#{plugins} plugins")
      |> maybe(queued != "0", "q#{queued}")
      |> maybe(hooks != "idle", "hooks #{hooks}")
      |> Enum.join("   ")

    notification =
      case Map.get(opts, :notifications, []) do
        [note | _rest] -> note
        _none -> nil
      end

    hints =
      cond do
        is_binary(notification) -> notification
        mode == :palette -> "Up/Dn  Enter run  Esc"
        true -> "/  commands     Up/^P history     ^Y yank     ^C  exit"
      end

    hint_col = max(width - String.length(hints) - @left, @left)
    hint_style = if Map.get(opts, :notifications, []) != [], do: :accent, else: :muted

    screen
    |> Screen.put_text(@left, row, clip(left, hint_col - @left - 2), :dim)
    |> Screen.put_text(hint_col, row, hints, hint_style)
  end

  defp maybe(list, false, _item), do: list
  defp maybe(list, true, item), do: list ++ [item]

  defp center(screen, y, width, text, style) do
    x = max(div(width - Screen.text_width(text), 2), 0)
    Screen.put_text(screen, x, y, text, style)
  end

  defp health_indicator(kv) do
    case Map.get(kv, "status", "starting") do
      "healthy" -> {"*", :ok}
      "ready" -> {"*", :ok}
      "starting" -> {"*", :warn}
      _other -> {"*", :err}
    end
  end

  # The split surfaces only while a runtime workflow is live; otherwise the
  # calm single transcript stays (and snapshot tests with empty panes too).
  defp mcp_active?(sections), do: count_sessions(sections) > 0

  # Left: scrollable conversation transcript. Right: MCP internals, parent
  # workflow on top, child session stream on the bottom. The split is what
  # makes streaming legible instead of a flat interleaved log.
  # OpenCode-style: no box-per-pane. One dim vertical rule is the only
  # separator; the right column is a bare titled telemetry sidebar whose
  # sections size to their content, not to the region. A too-narrow terminal
  # collapses cleanly back to a single full-width transcript.
  @mcp_right_min 28

  defp split_left_w(width), do: max(div(width * 3, 5), 32)

  defp draw_runtime_split(
         screen,
         width,
         left_top,
         right_top,
         bottom,
         activity,
         sections,
         scroll,
         reasoning
       ) do
    left_w = split_left_w(width)
    right_w = width - left_w - 1

    if right_w < @mcp_right_min do
      draw_transcript_if_room(screen, width, left_top, bottom, activity, true, scroll)
    else
      draw_runtime_split_two_column(
        screen,
        left_w,
        right_w,
        left_top,
        right_top,
        bottom,
        activity,
        sections,
        scroll,
        reasoning
      )
    end
  end

  defp draw_runtime_split_two_column(
         screen,
         left_w,
         right_w,
         left_top,
         right_top,
         bottom,
         activity,
         sections,
         scroll,
         reasoning
       ) do
    right_x = left_w + 1
    panel_h = max(bottom - right_top + 1, 1)
    # The pane is a self-contained shaded surface with one row of breathing
    # room on every side; sections lay out inside that padded box.
    inner_x = right_x + 1
    inner_w = max(right_w - 2, 1)
    inner_top = right_top + 1
    region = max(bottom - inner_top + 1, 1)

    body = section_body(sections, "Parent/Child Sessions")
    parent_lines = runtime_pane_lines(body, "parent ")
    child_lines = runtime_pane_lines(body, "child ")

    # The interview reasoning section sits on top of the MCP telemetry so the
    # "why this question" is the first thing the eye lands on; it only renders
    # when the wire actually carried reasoning.
    iv_h = if reasoning == [], do: 0, else: min(length(reasoning), max(div(region, 3), 1)) + 2

    rest = max(region - iv_h, 2)
    {parent_body_h, child_body_h} = mcp_section_heights(parent_lines, child_lines, rest)

    parent_top = inner_top + iv_h
    child_top = parent_top + 1 + parent_body_h + 1

    # OpenCode separates the sidebar from the conversation with whitespace,
    # not a full-height rule. The transcript stops a few columns short of the
    # sidebar so a clean gutter — not a hard line — divides the columns.
    transcript_clip_w = max(left_w - @body - @left, 1)

    screen
    |> draw_transcript_if_room(
      left_w,
      left_top,
      bottom,
      activity,
      true,
      scroll,
      transcript_clip_w
    )
    |> Screen.fill_rect(right_x, right_top, right_w, panel_h, :p_fill)
    |> maybe_draw_interview_section(inner_x, inner_top, inner_w, reasoning, iv_h)
    |> draw_mcp_section(inner_x, parent_top, inner_w, "MCP parent", parent_lines, parent_body_h)
    |> draw_mcp_section(inner_x, child_top, inner_w, "child stream", child_lines, child_body_h)
  end

  defp draw_transcript_if_room(screen, width, top, bottom, activity, hint, scroll, clip \\ nil)

  defp draw_transcript_if_room(screen, _width, top, bottom, _activity, _hint, _scroll, _clip)
       when top > bottom,
       do: screen

  defp draw_transcript_if_room(screen, width, top, bottom, activity, hint, scroll, clip) do
    draw_transcript(screen, width, top, bottom, activity, hint, scroll, clip)
  end

  defp maybe_draw_interview_section(screen, _x, _y, _w, [], _h), do: screen

  defp maybe_draw_interview_section(screen, x, y, w, reasoning, iv_h) do
    draw_mcp_section(screen, x, y, w, "interview", reasoning, max(iv_h - 2, 1))
  end

  # The pinned, prominent interview block (OpenCode message-block style: an
  # accent rail + marker, emphasized content, dim key hint). Long lines
  # word-wrap to the left-column width instead of truncating or bleeding into
  # the right pane. Returns `{screen, used_rows}` so the transcript flows
  # below the *actual* wrapped height.
  defp draw_interview_block(screen, top, w, marker, lines, hint, max_rows) do
    inner = max(w - @body - @left, 1)

    rows =
      lines
      |> Enum.flat_map(&wrap_logical_line(&1, inner))
      |> Enum.take(max_rows)

    screen =
      screen
      |> Screen.put_text(@left, top, "|", :accent)
      |> Screen.put_text(@body, top, clip(marker, inner), :brand)

    screen =
      rows
      |> Enum.with_index(1)
      |> Enum.reduce(screen, fn {{text, style}, i}, acc ->
        acc
        |> Screen.put_text(@left, top + i, "|", :accent)
        |> Screen.put_text(@body, top + i, clip(text, inner), style)
      end)

    hint_row = top + length(rows) + 1

    screen =
      screen
      |> Screen.put_text(@left, hint_row, "|", :accent)
      |> Screen.put_text(@body, hint_row, clip(hint, inner), :muted)

    {screen, 1 + length(rows) + 1}
  end

  # A logical line keeps one style for all of its wrapped segments;
  # continuation segments are indented two columns so a wrapped item still
  # reads as one. A {text, style} tuple carries an explicit color (the
  # color-coded dialogue rows); a bare string infers it (picked option
  # ">>"-led = accent, else strong) so string-only callers/tests are
  # unaffected.
  defp wrap_logical_line({text, style}, inner) when is_binary(text) do
    wrap_styled(text, style, inner)
  end

  defp wrap_logical_line(line, inner) when is_binary(line) do
    style = if String.starts_with?(line, ">> "), do: :accent, else: :strong
    wrap_styled(line, style, inner)
  end

  defp wrap_styled(text, style, inner) do
    text
    |> wrap_text(inner)
    |> Enum.with_index()
    |> Enum.map(fn
      {seg, 0} -> {seg, style}
      {seg, _n} -> {"  " <> seg, style}
    end)
  end

  # Greedy word-wrap to a display width (CJK-aware via Screen.text_width). A
  # single token wider than the line is hard-split so nothing is ever lost.
  @doc false
  @spec wrap_text(String.t(), pos_integer()) :: [String.t()]
  def wrap_text(text, width) when is_binary(text) and is_integer(width) and width > 0 do
    {lines, cur} =
      text
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reduce({[], ""}, fn word, {lines, cur} ->
        cond do
          Screen.text_width(word) > width ->
            [head | tail] = hard_split(word, width)
            flushed = if cur == "", do: lines, else: [cur | lines]
            stack = Enum.reduce(Enum.drop(tail, -1), [head | flushed], &[&1 | &2])
            {stack, List.last(tail) || head}

          cur == "" ->
            {lines, word}

          Screen.text_width(cur) + 1 + Screen.text_width(word) <= width ->
            {lines, cur <> " " <> word}

          true ->
            {[cur | lines], word}
        end
      end)

    case Enum.reverse([cur | lines]) |> Enum.reject(&(&1 == "")) do
      [] -> [""]
      wrapped -> wrapped
    end
  end

  def wrap_text(text, _width) when is_binary(text), do: [text]
  def wrap_text(_text, _width), do: [""]

  defp hard_split("", _width), do: []

  defp hard_split(word, width) do
    # Guarantee forward progress: a width too small for the first (possibly
    # double-width) grapheme would make truncate/2 return "" and recurse
    # forever, so take at least one grapheme.
    chunk =
      case Screen.truncate(word, width) do
        "" -> String.first(word)
        c -> c
      end

    case String.replace_prefix(word, chunk, "") do
      "" -> [chunk]
      rest -> [chunk | hard_split(rest, width)]
    end
  end

  # Sections shrink to their content (min 1 body row for an idle/failed
  # placeholder), each capped at half the region so one cannot starve the
  # other; if both together overflow, parent yields to keep child visible.
  defp mcp_section_heights(parent_lines, child_lines, region) do
    overhead = 2
    half = max(div(region, 2), 1)
    p_body = min(max(length(parent_lines), 1), half)
    c_body = min(max(length(child_lines), 1), half)

    if p_body + overhead + c_body + overhead <= region do
      {p_body, c_body}
    else
      p = max(min(p_body, region - 2 * overhead - 1), 1)
      c = max(region - (p + overhead) - overhead, 1)
      {p, c}
    end
  end

  # OpenCode-style sidebar block: a bold section header with a status token,
  # then dim content. No border/rule characters — whitespace separates the
  # sidebar from the conversation, mirroring OpenCode's `Context`/`LSP` blocks.
  defp draw_mcp_section(screen, x, y, w, title, lines, body_h) when w >= 4 and body_h >= 1 do
    {status, status_style} = mcp_section_status(lines)
    screen = Screen.put_text(screen, x, y, title, :p_title)

    screen =
      Screen.put_text(screen, x + String.length(title) + 1, y, status, status_style)

    rows =
      case lines do
        [] -> [{"idle", :p_muted}]
        lines -> lines |> Enum.take(-body_h) |> Enum.map(&{&1, mcp_line_style(&1)})
      end

    rows
    |> Enum.with_index(1)
    |> Enum.reduce(screen, fn {{text, style}, offset}, acc ->
      Screen.put_text(acc, x, y + offset, truncate_with_ellipsis(text, w - 1), style)
    end)
  end

  defp draw_mcp_section(screen, _x, _y, _w, _title, _lines, _body_h), do: screen

  defp mcp_section_status([]), do: {"idle", :p_muted}

  defp mcp_section_status(lines) do
    cond do
      Enum.any?(lines, &(&1 =~ ~r/failed|error/i)) -> {"failed", :p_err}
      true -> {"live", :p_accent}
    end
  end

  defp mcp_line_style(line) do
    cond do
      line =~ ~r/failed|error/i -> :p_err
      line == "idle" -> :p_muted
      true -> :p_dim
    end
  end

  defp truncate_with_ellipsis(text, max_width) when max_width <= 3 do
    Screen.truncate(text, max_width)
  end

  defp truncate_with_ellipsis(text, max_width) do
    if Screen.text_width(text) > max_width do
      Screen.truncate(text, max_width - 3) <> "..."
    else
      text
    end
  end

  defp runtime_pane_lines(body, prefix) do
    body
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(&String.replace_prefix(&1, prefix, ""))
    |> Enum.reject(&(&1 in ["empty", ""]))
    |> Enum.map(&humanize/1)
  end

  defp count_sessions(sections) do
    sections
    |> section_body("Parent/Child Sessions")
    |> Enum.count(&(&1 not in ["parent empty", "child empty", ""] and not region_marker?(&1)))
  end

  defp count_plugins(sections) do
    sections
    |> section_body("Plugin Status")
    |> Enum.count(&(&1 not in ["empty", ""] and not String.starts_with?(&1, "status=")))
  end

  defp section_body(sections, prefix) do
    Enum.find_value(sections, [], fn {title, body} ->
      if String.starts_with?(title, prefix), do: body, else: nil
    end)
  end

  defp status_fields(sections) do
    ["ourocode terminal", "State"]
    |> Enum.flat_map(&section_body(sections, &1))
    |> Enum.flat_map(&String.split(&1, " ", trim: true))
    |> Enum.reduce(%{}, fn token, acc ->
      case String.split(token, "=", parts: 2) do
        [k, v] when v != "" -> Map.put_new(acc, String.trim_trailing(k, "?"), v)
        _ -> acc
      end
    end)
  end

  # Strips machine `key=value` noise into a readable phrase while keeping the
  # SSoT projection as the upstream source of truth.
  defp humanize(line) do
    line
    |> String.replace(~r/\s+(region|x|y|w|h)=\S+/, "")
    |> String.replace("[OFFICIAL]", "OFFICIAL")
    |> String.replace("[THIRD-PARTY]", "THIRD-PARTY")
    |> String.replace(~r/\b(id|label|state|version|source)=/, "")
    |> String.replace(~r/\s{2,}/, " ")
    |> String.trim()
  end

  # The render model is the SSoT text projection; parsing it keeps the TUI
  # automatically in sync with every area renderer without duplicating them.
  defp parse_sections(frame) do
    frame
    |> String.split("\n")
    |> Enum.reduce({[], nil}, fn line, {sections, current} ->
      cond do
        String.starts_with?(line, "+-- ") ->
          sections = flush_section(sections, current)
          {sections, {section_title(line), []}}

        line == "+--" ->
          {flush_section(sections, current), nil}

        String.starts_with?(line, "| ") and current != nil ->
          {title, body} = current
          content = String.trim_leading(line, "| ")

          if region_marker?(content) do
            {sections, current}
          else
            {sections, {title, [content | body]}}
          end

        true ->
          {sections, current}
      end
    end)
    |> then(fn {sections, current} -> flush_section(sections, current) end)
    |> Enum.reverse()
  end

  defp flush_section(sections, nil), do: sections

  defp flush_section(sections, {title, body}) do
    [{title, Enum.reverse(body)} | sections]
  end

  defp section_title(line) do
    line
    |> String.trim_leading("+-- ")
    |> String.split(" region=", parts: 2)
    |> List.first()
    |> String.split(" x=", parts: 2)
    |> List.first()
    |> String.trim()
  end

  defp region_marker?(content) do
    Regex.match?(~r/^\[[a-z-]+-region\]\s+x=\d/, content)
  end

  # Full scroll-back: the captured output is the conversation buffer. The
  # renderer windows it by region + scroll offset, so nothing is silently
  # truncated to the last few lines anymore.
  defp activity_lines(output) do
    {_input, captured} = StringIO.contents(output)

    String.split(captured, "\n", trim: true)
  end

  defp cursor_to_prompt(state, rows, columns, prompt_buffer) do
    height = max(rows, @min_height)
    width = max(columns, @min_width)
    prefix = prompt_buffer |> String.graphemes() |> Enum.take(cursor(state)) |> Enum.join()
    # Composer input sits at row `height - 2` (0-indexed); ANSI is 1-indexed.
    ansi_row = height - 1
    ansi_col = min(@body + 1 + Screen.text_width(prefix), width)
    tty_write(state, "\e[#{ansi_row};#{ansi_col}H\e[?25h")
  end

  # Width-aware: CJK/fullwidth glyphs occupy two terminal columns.
  defp clip(text, max_width), do: Screen.truncate(text, max_width)

  defp normalize_paste(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.split("\n", trim: true)
    |> Enum.map(&normalize_paste_line/1)
    |> Enum.join(" ")
  end

  defp normalize_paste_line("file://" <> uri) do
    path = URI.decode(uri)

    if image_path?(path) do
      "@image:" <> path
    else
      path
    end
  end

  defp normalize_paste_line(line), do: line

  defp image_path?(path) do
    path
    |> String.downcase()
    |> String.match?(~r/\.(png|jpe?g|gif|webp|heic|heif)$/)
  end

  # --- terminal control (native helper) ------------------------------------

  # An escript cannot reliably raw-mode its controlling terminal (`stty` via
  # :os.cmd has no usable ctty), so a tiny native helper owns the tty: it
  # sets termios raw, reports size via TIOCGWINSZ, streams keystrokes to its
  # stdout, and writes frames from its stdin to the tty. We talk to it over
  # an OS pipe (a Port), which is reliable. This is the seed's replaceable
  # native frontend piece; the Elixir runtime stays the source of truth.

  @doc "Absolute path of the built tty helper, or nil if it is not present."
  @spec helper_path() :: String.t() | nil
  def helper_path do
    [
      System.get_env("OUROCODE_TTY"),
      Path.join(File.cwd!(), "rust/ourocode_ipc/target/release/ourocode_tty"),
      Path.join(File.cwd!(), "bin/ourocode_tty")
    ]
    |> Enum.find(fn p -> is_binary(p) and File.exists?(p) end)
  end

  defp start_driver(state) do
    case helper_path() do
      nil ->
        :error

      path ->
        # `:nouse_stdio` leaves the child's fds 0/1/2 inherited from the BEAM
        # (the real terminal) and moves this protocol channel to fds 3/4, so
        # the helper can raw-mode the actual terminal without a ctty.
        port =
          Port.open({:spawn_executable, String.to_charlist(path)}, [
            :binary,
            :exit_status,
            :nouse_stdio,
            :hide
          ])

        case read_header(port, "") do
          {:ok, cols, rows, rest} ->
            put_port(state, port)
            put_size(state, {cols, rows})
            put_inbuf(state, rest)
            # Keep mouse reporting off: the host terminal should own drag
            # selection and clipboard gestures while ourocode owns keyboard input.
            tty_write(state, terminal_enter_sequence())
            :ok

          :error ->
            safe_port_close(port)
            :error
        end
    end
  end

  # First stdout line from the helper is "<cols> <rows>\n"; anything after it
  # in the same packet is the start of the key byte stream.
  defp read_header(port, acc) do
    receive do
      {^port, {:data, data}} ->
        buf = acc <> data

        case :binary.split(buf, "\n") do
          [line, rest] ->
            case line |> String.split() |> Enum.map(&Integer.parse/1) do
              [{cols, _}, {rows, _}] when cols > 0 and rows > 0 ->
                {:ok, cols, rows, rest}

              _ ->
                :error
            end

          [_partial] ->
            read_header(port, buf)
        end

      {^port, {:exit_status, _}} ->
        :error
    after
      5_000 -> :error
    end
  end

  defp stop_driver(state) do
    case port(state) do
      nil ->
        :ok

      port ->
        tty_write(state, terminal_exit_sequence())
        safe_port_close(port)
    end
  end

  @doc false
  def terminal_enter_sequence, do: "\e[?1049h\e[?25l\e[2J\e[H"

  @doc false
  def terminal_exit_sequence, do: "\e[?25h\e[?1049l"

  defp safe_port_close(port) do
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  defp tty_write(state, iodata) do
    case port(state) do
      nil -> :ok
      port -> Port.command(port, IO.iodata_to_binary(iodata))
    end
  end

  # Returns the next raw input chunk: buffered remainder first, otherwise the
  # next packet from the helper. `:eof` when the helper exits.
  # ~0.5s wake so streamed MCP events (folded into live pane state off-loop)
  # repaint on a steady cadence without waiting for a keystroke, keeping the
  # first-visible-event budget well under the 5s ceiling.
  @poll_ms 500

  defp next_chunk(state) do
    case take_inbuf(state) do
      "" ->
        port = port(state)

        receive do
          {^port, {:data, data}} ->
            {:ok, data}

          {^port, {:exit_status, _}} ->
            :eof

          {:file_cache_ready, files} when is_list(files) ->
            put_file_cache(state, files)
            :tick
        after
          @poll_ms -> :tick
        end

      buffered ->
        {:ok, buffered}
    end
  end

  defp tty? do
    match?({:ok, _}, :io.columns())
  end

  defp refresh_size(state) do
    case {:io.columns(), :io.rows()} do
      {{:ok, cols}, {:ok, rows}} when cols > 0 and rows > 0 ->
        size = {cols, rows}
        put_size(state, size)
        size

      _other ->
        size(state)
    end
  rescue
    _exception -> size(state)
  end

  defp stdio_device?(:stdio), do: true
  defp stdio_device?(:standard_io), do: true
  defp stdio_device?(_other), do: false

  # --- driver state --------------------------------------------------------

  defp start_state do
    {:ok, pid} =
      Agent.start_link(fn ->
        draft = PromptStore.load_draft()

        %{
          buffer: draft,
          cursor: String.length(draft),
          leftover: "",
          prev_screen: nil,
          port: nil,
          inbuf: "",
          mode: :normal,
          pidx: 0,
          login: nil,
          streaming: false,
          key_help: false,
          tick: 0,
          size: {120, 40},
          model_id: nil,
          scroll: 0,
          wonder_nav: nil,
          history: PromptStore.load_history(),
          history_index: 0,
          history_draft: nil,
          file_cache: nil,
          ooo_cache: nil,
          ooo_cache_loaded_ms: nil,
          kill_ring: [],
          kill_index: 0,
          last_edit_was_kill: false,
          last_yank: nil,
          esc_armed_until: nil,
          notifications: []
        }
      end)

    pid
  end

  # Ephemeral selection cursor for the active wonderTool checkpoint (pure view
  # state — the runtime SSoT stays in LoopBindings). `nil` when no checkpoint.
  # When active: %{req_id, qidx, picks: %{question_index => option_index}}.
  defp wonder_nav(state), do: Agent.get(state, & &1.wonder_nav)
  defp put_wonder_nav(state, nav), do: Agent.update(state, &%{&1 | wonder_nav: nav})

  # Transcript scroll-back offset in rows: 0 follows the tail (latest), a
  # positive value scrolls up into history. Clamped by the renderer against
  # available history so it can never run past the buffer.
  defp scroll_off(state), do: Agent.get(state, & &1.scroll)

  defp put_scroll(state, value) do
    Agent.update(state, &%{&1 | scroll: max(value, 0)})
  end

  defp scroll_by(state, delta), do: put_scroll(state, scroll_off(state) + delta)

  defp model_id(state), do: Agent.get(state, & &1.model_id)
  defp put_model_id(state, id), do: Agent.update(state, &%{&1 | model_id: id})
  defp size(state), do: Agent.get(state, & &1.size)
  defp put_size(state, wh), do: Agent.update(state, &%{&1 | size: wh})
  defp get_mode(state), do: Agent.get(state, & &1.mode)
  defp put_mode(state, mode), do: Agent.update(state, &%{&1 | mode: mode})
  defp pidx(state), do: Agent.get(state, & &1.pidx)
  defp put_pidx(state, index), do: Agent.update(state, &%{&1 | pidx: index})
  defp login_state(state), do: Agent.get(state, & &1.login)
  defp put_login(state, login), do: Agent.update(state, &%{&1 | login: login})
  defp streaming?(state), do: Agent.get(state, & &1.streaming)
  defp set_streaming(state, on), do: Agent.update(state, &%{&1 | streaming: on})
  defp key_help?(state), do: Agent.get(state, & &1.key_help)
  defp toggle_key_help(state), do: Agent.update(state, &%{&1 | key_help: not &1.key_help})
  defp tick(state), do: Agent.get(state, & &1.tick)
  defp bump_tick(state), do: Agent.update(state, &%{&1 | tick: &1.tick + 1})

  defp file_cache(state) do
    case Agent.get(state, & &1.file_cache) do
      files when is_list(files) ->
        files

      :loading ->
        []

      _none ->
        start_file_cache(state)
        []
    end
  end

  defp start_file_cache(state) do
    owner = self()

    started? =
      Agent.get_and_update(state, fn s ->
        case s.file_cache do
          nil -> {true, %{s | file_cache: :loading}}
          _other -> {false, s}
        end
      end)

    if started? do
      _ =
        Task.start(fn ->
          send(owner, {:file_cache_ready, discover_files()})
        end)
    end

    :ok
  end

  defp put_file_cache(state, files) when is_list(files) do
    Agent.update(state, &%{&1 | file_cache: files})
  end

  defp discover_files do
    case System.find_executable("rg") do
      nil ->
        []

      _rg ->
        case System.cmd("rg", ["--files"], cd: File.cwd!(), stderr_to_stdout: true) do
          {out, 0} ->
            out
            |> String.split("\n", trim: true)
            |> Enum.reject(&ignored_file_path?/1)
            |> Enum.take(1_000)

          _other ->
            []
        end
    end
  rescue
    _exception -> []
  end

  defp ignored_file_path?(path) do
    String.starts_with?(path, ["_build/", "deps/", ".git/"]) or
      String.contains?(path, ["/_build/", "/deps/", "/.git/"])
  end

  defp notifications(state) do
    now = System.monotonic_time(:millisecond)

    Agent.get_and_update(state, fn s ->
      active =
        s.notifications
        |> Enum.filter(fn {_text, until_ms} -> until_ms > now end)
        |> Enum.take(3)

      {Enum.map(active, fn {text, _until_ms} -> text end), %{s | notifications: active}}
    end)
  end

  defp push_notification(state, text, ttl_ms \\ 1_500) do
    until_ms = System.monotonic_time(:millisecond) + ttl_ms

    Agent.update(state, fn s ->
      %{s | notifications: [{text, until_ms} | s.notifications] |> Enum.take(3)}
    end)
  end

  defp port(state), do: Agent.get(state, & &1.port)
  defp put_port(state, port), do: Agent.update(state, &%{&1 | port: port})
  defp put_inbuf(state, bytes), do: Agent.update(state, &%{&1 | inbuf: bytes})
  defp take_inbuf(state), do: Agent.get_and_update(state, &{&1.inbuf, %{&1 | inbuf: ""}})

  defp buffer(state), do: Agent.get(state, & &1.buffer)
  defp cursor(state), do: Agent.get(state, & &1.cursor)

  defp edit_buffer(state, event) do
    Agent.update(state, fn s ->
      s = edit_state(s, event)
      PromptStore.save_draft(s.buffer)
      s
    end)
  end

  @double_press_ms 800

  defp handle_escape_clear(state) do
    now = System.monotonic_time(:millisecond)

    Agent.update(state, fn s ->
      cond do
        s.buffer == "" ->
          %{s | esc_armed_until: nil, notifications: []}

        is_integer(s.esc_armed_until) and s.esc_armed_until >= now ->
          %{
            s
            | buffer: "",
              cursor: 0,
              history_index: 0,
              history_draft: nil,
              esc_armed_until: nil,
              notifications: [{"input cleared", now + 1_000} | s.notifications] |> Enum.take(3)
          }

        true ->
          %{
            s
            | esc_armed_until: now + @double_press_ms,
              notifications:
                [{"Esc again to clear input", now + @double_press_ms} | s.notifications]
                |> Enum.take(3)
          }
      end
    end)

    PromptStore.save_draft(buffer(state))
  end

  defp edit_state(s, %{key: :ctrl_y}) do
    case List.first(s.kill_ring) do
      text when is_binary(text) and text != "" ->
        {buffer, cursor} = edit_input(s.buffer, s.cursor, %{key: :paste, char: text})

        %{
          s
          | buffer: buffer,
            cursor: cursor,
            kill_index: 0,
            last_yank: {s.cursor, String.length(text)}
        }

      _none ->
        s
    end
  end

  defp edit_state(%{last_yank: {start, len}, kill_ring: ring} = s, %{key: :alt_y})
       when length(ring) > 1 do
    index = Integer.mod(s.kill_index + 1, length(ring))
    text = Enum.at(ring, index, "")
    graphemes = String.graphemes(s.buffer)
    {left, rest} = Enum.split(graphemes, start)
    {_old, right} = Enum.split(rest, len)
    insert = String.graphemes(text)
    buffer = Enum.join(left ++ insert ++ right)

    %{
      s
      | buffer: buffer,
        cursor: start + length(insert),
        kill_index: index,
        last_yank: {start, length(insert)}
    }
  end

  defp edit_state(s, event) do
    killed = killed_text(s.buffer, s.cursor, event)
    {buffer, cursor} = edit_input(s.buffer, s.cursor, event)

    base =
      Map.merge(s, %{
        buffer: buffer,
        cursor: cursor,
        last_yank: nil,
        last_edit_was_kill: killed != "",
        esc_armed_until: nil,
        notifications: []
      })

    maybe_push_kill(base, killed, kill_direction(event), s.last_edit_was_kill)
  end

  @doc false
  def edit_input(buffer, cursor, event) when is_binary(buffer) and is_integer(cursor) do
    graphemes = String.graphemes(buffer)
    cursor = clamp_cursor(cursor, length(graphemes))

    {edited, cursor} =
      case event do
        %{key: :char, char: grapheme} when is_binary(grapheme) ->
          insert_text(graphemes, cursor, grapheme)

        %{key: :paste, char: text} when is_binary(text) ->
          insert_text(graphemes, cursor, normalize_paste(text))

        %{key: :backspace} ->
          delete_before(graphemes, cursor)

        %{key: :delete} ->
          delete_at(graphemes, cursor)

        %{key: :ctrl_d} ->
          delete_at(graphemes, cursor)

        %{key: :left} ->
          {graphemes, max(cursor - 1, 0)}

        %{key: :ctrl_b} ->
          {graphemes, max(cursor - 1, 0)}

        %{key: :right} ->
          {graphemes, min(cursor + 1, length(graphemes))}

        %{key: :ctrl_f} ->
          {graphemes, min(cursor + 1, length(graphemes))}

        %{key: :home} ->
          {graphemes, 0}

        %{key: :ctrl_a} ->
          {graphemes, 0}

        %{key: :end} ->
          {graphemes, length(graphemes)}

        %{key: :ctrl_e} ->
          {graphemes, length(graphemes)}

        %{key: :ctrl_u} ->
          {Enum.drop(graphemes, cursor), 0}

        %{key: :ctrl_k} ->
          {Enum.take(graphemes, cursor), cursor}

        %{key: :cmd_backspace} ->
          {[], 0}

        %{key: :ctrl_backspace} ->
          delete_word_before(graphemes, cursor)

        %{key: :ctrl_w} ->
          delete_word_before(graphemes, cursor)

        %{key: :ctrl_y} ->
          {graphemes, cursor}

        %{key: :alt_b} ->
          {graphemes, word_before(graphemes, cursor)}

        %{key: :alt_f} ->
          {graphemes, word_after(graphemes, cursor)}

        %{key: :alt_d} ->
          delete_word_after(graphemes, cursor)

        %{key: :alt_y} ->
          {graphemes, cursor}

        _other ->
          {graphemes, cursor}
      end

    text = Enum.join(edited)
    {text, clamp_cursor(cursor, String.length(text))}
  end

  defp insert_text(graphemes, cursor, text) do
    insert = String.graphemes(text)
    {left, right} = Enum.split(graphemes, cursor)
    {left ++ insert ++ right, cursor + length(insert)}
  end

  defp delete_before(graphemes, 0), do: {graphemes, 0}

  defp delete_before(graphemes, cursor) do
    {left, right} = Enum.split(graphemes, cursor)
    {Enum.drop(left, -1) ++ right, cursor - 1}
  end

  defp delete_at(graphemes, cursor) do
    {left, right} = Enum.split(graphemes, cursor)
    {left ++ Enum.drop(right, 1), cursor}
  end

  defp delete_word_before(graphemes, cursor) do
    start = word_before(graphemes, cursor)
    {left, rest} = Enum.split(graphemes, start)
    {_deleted, right} = Enum.split(rest, cursor - start)
    {left ++ right, start}
  end

  defp delete_word_after(graphemes, cursor) do
    stop = word_after(graphemes, cursor)
    {left, rest} = Enum.split(graphemes, cursor)
    {_deleted, right} = Enum.split(rest, stop - cursor)
    {left ++ right, cursor}
  end

  defp word_before(graphemes, cursor) do
    reversed =
      graphemes
      |> Enum.take(cursor)
      |> Enum.reverse()

    blanks = drop_while_index(reversed, &blank?/1)

    word =
      reversed
      |> Enum.drop(blanks)
      |> drop_while_index(&(not blank?(&1)))

    max(cursor - blanks - word, 0)
  end

  defp word_after(graphemes, cursor) do
    tail = Enum.drop(graphemes, cursor)

    skipped =
      drop_while_index(tail, &blank?/1) +
        (tail
         |> Enum.drop(drop_while_index(tail, &blank?/1))
         |> drop_while_index(&(not blank?(&1))))

    min(cursor + skipped, length(graphemes))
  end

  defp drop_while_index(graphemes, pred) do
    Enum.reduce_while(graphemes, 0, fn g, idx ->
      if pred.(g), do: {:cont, idx + 1}, else: {:halt, idx}
    end)
  end

  defp blank?(grapheme), do: String.match?(grapheme, ~r/\s/u)

  defp clamp_cursor(cursor, len), do: cursor |> max(0) |> min(len)

  defp killed_text(buffer, cursor, event) do
    graphemes = String.graphemes(buffer)
    cursor = clamp_cursor(cursor, length(graphemes))

    {from, to} =
      case event do
        %{key: :ctrl_u} ->
          {0, cursor}

        %{key: :cmd_backspace} ->
          {0, length(graphemes)}

        %{key: :ctrl_k} ->
          {cursor, length(graphemes)}

        %{key: key} when key in [:ctrl_w, :ctrl_backspace] ->
          {word_before(graphemes, cursor), cursor}

        %{key: :alt_d} ->
          {cursor, word_after(graphemes, cursor)}

        _other ->
          {0, 0}
      end

    if to > from do
      graphemes |> Enum.slice(from, to - from) |> Enum.join()
    else
      ""
    end
  end

  defp kill_direction(%{key: key})
       when key in [:ctrl_u, :ctrl_w, :ctrl_backspace, :cmd_backspace],
       do: :prepend

  defp kill_direction(_event), do: :append

  @kill_ring_limit 10

  defp maybe_push_kill(s, "", _direction, _accumulating?), do: s

  defp maybe_push_kill(s, text, direction, accumulating?) do
    ring =
      case {s.kill_ring, direction, accumulating?} do
        {[], _direction, _accumulating?} -> [text]
        {ring, _direction, false} -> [text | ring]
        {[head | tail], :prepend, true} -> [text <> head | tail]
        {[head | tail], :append, true} -> [head <> text | tail]
      end
      |> Enum.take(@kill_ring_limit)

    %{s | kill_ring: ring, kill_index: 0}
  end

  @history_limit 50

  defp remember_history(_state, ""), do: :ok

  defp remember_history(state, line) when is_binary(line) do
    Agent.update(state, fn s ->
      history =
        case List.first(s.history) do
          ^line -> s.history
          _other -> [line | s.history] |> Enum.take(@history_limit)
        end

      %{
        s
        | history: history,
          history_index: 0,
          history_draft: nil,
          ooo_cache: nil,
          ooo_cache_loaded_ms: nil
      }
    end)

    PromptStore.append_history(line)
  end

  defp move_history(state, direction) when direction in [-1, 1] do
    Agent.update(state, fn s ->
      count = length(s.history)

      cond do
        count == 0 ->
          s

        direction == -1 ->
          index = min(s.history_index + 1, count)
          draft = if s.history_index == 0, do: s.buffer, else: s.history_draft
          buffer = Enum.at(s.history, index - 1, "")

          %{
            s
            | history_index: index,
              history_draft: draft,
              buffer: buffer,
              cursor: String.length(buffer)
          }

        direction == 1 and s.history_index > 1 ->
          index = s.history_index - 1
          buffer = Enum.at(s.history, index - 1, "")
          %{s | history_index: index, buffer: buffer, cursor: String.length(buffer)}

        direction == 1 and s.history_index == 1 ->
          buffer = s.history_draft || ""

          %{
            s
            | history_index: 0,
              history_draft: nil,
              buffer: buffer,
              cursor: String.length(buffer)
          }

        true ->
          s
      end
    end)
  end

  defp reset_history_cursor(state) do
    Agent.update(state, fn s -> %{s | history_index: 0, history_draft: nil} end)
  end

  defp take_buffer(state) do
    PromptStore.clear_draft()
    Agent.get_and_update(state, fn s -> {s.buffer, %{s | buffer: "", cursor: 0}} end)
  end

  defp take_leftover(state) do
    Agent.get_and_update(state, fn s -> {s.leftover, %{s | leftover: ""}} end)
  end

  defp put_leftover(state, leftover) do
    Agent.update(state, fn s -> %{s | leftover: leftover} end)
  end

  defp prev_screen(state), do: Agent.get(state, & &1.prev_screen)

  defp put_prev_screen(state, screen) do
    Agent.update(state, fn s -> %{s | prev_screen: screen} end)
  end
end
