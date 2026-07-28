defmodule Ourocode.Model.ConversationTest do
  use ExUnit.Case, async: true

  alias Ourocode.Model.Conversation

  test "render_prompt passes the prompt through byte-identical with no history" do
    assert Conversation.render_prompt(Conversation.new(), "hello") == "hello"
  end

  test "render_prompt replays turns in order before the current message" do
    conversation =
      Conversation.new()
      |> Conversation.add_turn("what is the entrypoint?", "Ourocode.CLI")
      |> Conversation.add_turn("and the tty layer?", "rust/ourocode_ipc")

    prompt = Conversation.render_prompt(conversation, "how do they talk?")

    assert prompt =~ "## Conversation so far"
    assert prompt =~ "user: what is the entrypoint?\nassistant: Ourocode.CLI"
    assert prompt =~ "user: and the tty layer?\nassistant: rust/ourocode_ipc"
    assert prompt =~ "## Current message\nhow do they talk?"

    [first, second] =
      Regex.scan(~r/user: ([^\n]+)/, prompt) |> Enum.map(fn [_, captured] -> captured end)

    assert first == "what is the entrypoint?"
    assert second == "and the tty layer?"
  end

  test "render_prompt normalizes CRLF transcript boundaries without losing content" do
    conversation =
      Conversation.new()
      |> Conversation.add_turn("first line\r\nsecond line", "answer line\r\nnext answer")

    prompt = Conversation.render_prompt(conversation, "current line\r\nnext current")

    refute prompt =~ "\r"
    assert prompt =~ "user: first line\nsecond line\nassistant: answer line\nnext answer"
    assert prompt =~ "## Current message\ncurrent line\nnext current"
  end

  test "render_prompt keeps a contiguous recent window under the byte budget" do
    big = String.duplicate("a", 3_000)

    conversation =
      Enum.reduce(1..10, Conversation.new(), fn n, conversation ->
        Conversation.add_turn(conversation, "question #{n}", big)
      end)

    prompt = Conversation.render_prompt(conversation, "now?")

    # 10 turns x ~3KB exceeds the 16KB budget: the oldest turns are elided
    # and the marker counts them.
    assert prompt =~ ~r/\[\d+ earlier turn\(s\) elided\]/
    assert prompt =~ "question 10"
    refute prompt =~ "question 1\n"
  end

  test "add_turn caps an oversized reply at a valid UTF-8 boundary" do
    long = "a" <> String.duplicate("가", 5_000)
    conversation = Conversation.add_turn(Conversation.new(), "q", long)

    [%{assistant: stored}] = conversation.turns
    assert byte_size(stored) < byte_size(long)
    assert String.valid?(stored)
    assert stored =~ "...[truncated]"
  end

  test "to_list/from_list roundtrips and drops junk entries" do
    conversation =
      Conversation.new()
      |> Conversation.add_turn("ping", "pong")
      |> Conversation.add_turn("다시", "응답")

    listed = Conversation.to_list(conversation)

    assert listed == [
             %{"user" => "ping", "assistant" => "pong"},
             %{"user" => "다시", "assistant" => "응답"}
           ]

    assert Conversation.from_list(listed) == conversation

    junk = listed ++ [%{"user" => 42}, "noise", %{"assistant" => "only"}]
    assert Conversation.from_list(junk) == conversation
    assert Conversation.from_list("garbage") == Conversation.new()
  end

  test "input_items renders alternating roles ending with the current prompt" do
    conversation = Conversation.add_turn(Conversation.new(), "ping", "pong")

    assert Conversation.input_items(conversation, "again") == [
             %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "ping"}]},
             %{
               "role" => "assistant",
               "content" => [%{"type" => "output_text", "text" => "pong"}]
             },
             %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "again"}]}
           ]
  end
end
