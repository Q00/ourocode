defmodule Ourocode.Terminal.HistorySearch do
  @moduledoc """
  Pure reverse-incremental search over prompt history (Ctrl-R).

  History is stored newest-first, so scanning in order yields the most recent
  match first. `skip` selects the Nth (0-based) match, which is how repeated
  Ctrl-R walks toward older matches. An empty query matches every entry.
  """

  @spec find([String.t()], String.t(), non_neg_integer()) ::
          {String.t(), pos_integer()} | :none
  def find(history, query, skip \\ 0)
      when is_list(history) and is_binary(query) and is_integer(skip) and skip >= 0 do
    history
    |> Enum.with_index(1)
    |> Enum.filter(fn {entry, _index} -> String.contains?(entry, query) end)
    |> Enum.at(skip)
    |> case do
      nil -> :none
      {entry, index} -> {entry, index}
    end
  end
end
