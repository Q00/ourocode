defmodule Ourocode.Terminal.TuiSearchEvent do
  @moduledoc """
  Key handling for reverse-incremental history search (Ctrl-R) mode.

  Typing extends the query, Ctrl-R walks to the next older match, Enter accepts
  the current match into the prompt buffer (back in normal mode, ready to edit
  or submit), and Esc restores the buffer that was there when search began.
  """

  alias Ourocode.Terminal.TuiState

  @spec handle(map(), pid(), map(), (-> any()), (-> any())) ::
          :continue | :exit | {:submit, String.t()}
  def handle(event, state, _callbacks, draw, cont) do
    case event do
      %{key: :char, char: char} when is_binary(char) ->
        TuiState.search_type(state, char)
        redraw(draw, cont)

      %{key: :ctrl_r} ->
        TuiState.search_older(state)
        redraw(draw, cont)

      %{key: :backspace} ->
        TuiState.search_backspace(state)
        redraw(draw, cont)

      %{key: :enter} ->
        TuiState.accept_search(state)
        redraw(draw, cont)

      %{key: :escape} ->
        TuiState.cancel_search(state)
        redraw(draw, cont)

      _other ->
        cont.()
    end
  end

  defp redraw(draw, cont) do
    draw.()
    cont.()
  end
end
