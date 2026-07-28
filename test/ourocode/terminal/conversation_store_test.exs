defmodule Ourocode.Terminal.ConversationStoreTest do
  use ExUnit.Case, async: true

  alias Ourocode.Model.Conversation
  alias Ourocode.Terminal.ConversationStore

  test "save/load roundtrips a conversation per project" do
    state_dir = state_dir!()
    project = "/tmp/demo-project"
    other = "/tmp/other-project"

    conversation = Conversation.add_turn(Conversation.new(), "ping", "pong")
    assert :ok = ConversationStore.save(project, conversation, state_dir: state_dir)

    loaded = ConversationStore.load(project, state_dir: state_dir)
    assert loaded.turns == [%{user: "ping", assistant: "pong"}]

    # Distinct projects do not share a dialogue.
    assert Conversation.empty?(ConversationStore.load(other, state_dir: state_dir))
  end

  test "load returns an empty conversation for missing or corrupt files" do
    state_dir = state_dir!()
    project = "/tmp/demo-project"

    assert Conversation.empty?(ConversationStore.load(project, state_dir: state_dir))

    conversation = Conversation.add_turn(Conversation.new(), "a", "b")
    :ok = ConversationStore.save(project, conversation, state_dir: state_dir)
    [file] = wildcard_chat_files(state_dir)
    File.write!(file, "{not json")

    assert Conversation.empty?(ConversationStore.load(project, state_dir: state_dir))
  end

  test "clear removes the persisted dialogue" do
    state_dir = state_dir!()
    project = "/tmp/demo-project"

    :ok =
      ConversationStore.save(
        project,
        Conversation.add_turn(Conversation.new(), "a", "b"),
        state_dir: state_dir
      )

    assert :ok = ConversationStore.clear(project, state_dir: state_dir)
    assert Conversation.empty?(ConversationStore.load(project, state_dir: state_dir))
  end

  test "nil project dir is a no-op store" do
    assert Conversation.empty?(ConversationStore.load(nil, state_dir: state_dir!()))
    assert :ok = ConversationStore.save(nil, Conversation.new(), state_dir: state_dir!())
    assert :ok = ConversationStore.clear(nil, state_dir: state_dir!())
  end

  test "project_dir reads the startup result shapes" do
    assert ConversationStore.project_dir(%{context: %{project_dir: "/a"}}) == "/a"
    assert ConversationStore.project_dir(%{project_dir: "/b"}) == "/b"
    assert ConversationStore.project_dir(%{}) == nil
  end

  defp state_dir! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ourocode-conversation-store-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp wildcard_chat_files(state_dir) do
    [state_dir, "chat", "*.json"]
    |> Path.join()
    |> String.replace("\\", "/")
    |> Path.wildcard()
  end
end
