defmodule Ourocode.Terminal.TuiStateInitial do
  @moduledoc """
  Builds the initial Agent state for the interactive TUI.
  """

  alias Ourocode.Terminal.PromptStore

  @spec build() :: map()
  def build do
    draft = PromptStore.load_draft()

    %{
      buffer: draft,
      cursor: String.length(draft),
      leftover: "",
      activity_lines: [],
      prev_screen: nil,
      render_theme: nil,
      port: nil,
      inbuf: "",
      mode: :normal,
      pidx: 0,
      login: nil,
      pending_login: nil,
      last_turn_ms: nil,
      streaming: false,
      key_help: false,
      live_turn_event: nil,
      tick: 0,
      size: {120, 40},
      model_id: nil,
      model_slug_by_provider: %{},
      model_cache: nil,
      scroll: 0,
      workspace: nil,
      wonder_nav: nil,
      interview_ledger_selected_id: nil,
      interview_ledger_hover_id: nil,
      interview_ledger_hit_map: %{},
      mcp_ledger_selected_id: nil,
      mcp_ledger_hover_id: nil,
      mcp_ledger_hit_map: %{},
      force_interview_paused: false,
      interview_cancelled: false,
      history: PromptStore.load_history(),
      history_index: 0,
      history_draft: nil,
      history_prefix: nil,
      search_query: "",
      search_skip: 0,
      search_origin_buffer: nil,
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
  end
end
