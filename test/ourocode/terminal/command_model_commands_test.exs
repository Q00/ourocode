defmodule Ourocode.Terminal.CommandModelCommandsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{CommandHandler, CommandInput, CommandModelCommands, TuiState}

  setup do
    {:ok, output} = StringIO.open("")
    tui_state = TuiState.start_link()

    on_exit(fn ->
      safe_close(output, &StringIO.close/1)
      safe_close(tui_state, &Agent.stop/1)
    end)

    %{output: output, tui_state: tui_state, state: %{output: output, tui_state: tui_state}}
  end

  test "render select_provider shows provider/backend picker surface", %{
    state: state,
    output: output
  } do
    assert {:ok, %{status: :rendered, workspace: workspace, count: count}} =
             CommandModelCommands.render(:select_provider, state)

    {_input, text} = StringIO.contents(output)

    assert count > 0
    assert workspace.kind == "provider"
    assert workspace.title == "Providers"
    assert workspace.next =~ "choose a ready CLI provider"
    assert Enum.any?(workspace.records, &String.starts_with?(&1.id, "provider:"))
    assert Enum.any?(workspace.actions, &(&1.command == "/login"))
    assert Enum.any?(workspace.actions, &(&1.command == "/verify"))
    assert text =~ "Providers"
    assert text =~ "provider"
    assert text =~ "/login"
    assert text =~ "/verify"
  end

  test "render show_model_commands lists active provider model slugs", %{
    state: state,
    tui_state: tui_state,
    output: output
  } do
    TuiState.put_model_id(tui_state, :codex)

    assert {:ok, %{status: :rendered, workspace: workspace, count: 2}} =
             CommandModelCommands.render(
               :show_model_commands,
               %{command: "/model", args: []},
               state
             )

    {_input, text} = StringIO.contents(output)

    assert workspace.kind == "model"
    assert workspace.title == "Codex models"
    assert workspace.status == "active gpt-5.5"
    assert workspace.selected == "model:gpt-5.5"
    assert Enum.map(workspace.records, & &1.title) == ["gpt-5.5", "gpt-5.3-codex"]
    assert workspace.detail.fields.command == "/model gpt-5.5"
    assert Enum.any?(workspace.actions, &(&1.command == "/provider"))
    assert workspace.shortcuts == ["type /model <slug>", "use /provider for backends"]
    assert workspace.next =~ "Use /model <slug>"

    assert text =~ "Codex models"
    assert text =~ "gpt-5.5"
    assert text =~ "gpt-5.3-codex"
    assert text =~ "/provider"
    assert text =~ "Use /model <slug>"
    refute text =~ "Pick the active main-session provider/backend."
  end

  test "models alias renders the same active provider model list", %{
    state: state,
    tui_state: tui_state,
    output: output
  } do
    TuiState.put_model_id(tui_state, :codex)

    assert {:ok, %{status: :rendered, workspace: workspace}} =
             CommandHandler.handle(CommandInput.command_event("/models"), command_state(state))

    {_input, text} = StringIO.contents(output)

    assert workspace.kind == "model"
    assert workspace.selected == "model:gpt-5.5"
    assert text =~ "gpt-5.5"
    assert text =~ "gpt-5.3-codex"
  end

  test "direct codex slug selection persists the provider-specific model slug", %{
    state: state,
    tui_state: tui_state,
    output: output
  } do
    TuiState.put_model_id(tui_state, :codex)

    assert {:ok, %{status: :selected, provider_id: :codex, slug: "gpt-5.5"}} =
             CommandHandler.handle(
               CommandInput.command_event("/model gpt-5.5"),
               command_state(state)
             )

    assert TuiState.provider_model_slug(tui_state, :codex) == "gpt-5.5"

    {_input, text} = StringIO.contents(output)
    assert text =~ "model: gpt-5.5 selected for codex"
  end

  test "invalid slug and extra words report visible errors without mutating active slug", %{
    state: state,
    tui_state: tui_state,
    output: output
  } do
    TuiState.put_model_id(tui_state, :codex)
    TuiState.put_provider_model_slug(tui_state, :codex, "gpt-5.5")

    assert {:error, {:invalid_model_slug, :unknown_slug}} =
             CommandHandler.handle(
               CommandInput.command_event("/model invalid-slug"),
               command_state(state)
             )

    assert TuiState.provider_model_slug(tui_state, :codex) == "gpt-5.5"

    assert {:error, {:invalid_model_slug_args, ["gpt-5.3-codex", "extra"]}} =
             CommandHandler.handle(
               CommandInput.command_event("/model gpt-5.3-codex extra"),
               command_state(state)
             )

    assert TuiState.provider_model_slug(tui_state, :codex) == "gpt-5.5"

    {_input, text} = StringIO.contents(output)
    assert text =~ "model: unknown slug invalid-slug for codex"
    assert text =~ "model: use /model <slug> with exactly one slug"
  end

  test "providers without a model catalog render a clear visible empty state", %{
    state: state,
    tui_state: tui_state,
    output: output
  } do
    TuiState.put_model_id(tui_state, :gemini)

    assert {:ok, %{status: :empty, workspace: workspace, count: 0}} =
             CommandHandler.handle(CommandInput.command_event("/model"), command_state(state))

    {_input, text} = StringIO.contents(output)

    assert workspace.kind == "model"
    assert workspace.title == "Gemini models"
    assert workspace.records == []
    assert text =~ "No model list is available for gemini"
  end

  defp command_state(state) do
    Map.put_new(state, :startup_result, %{commands: %{entries: [], aliases: %{}}})
  end

  defp safe_close(pid, close) when is_pid(pid) and is_function(close, 1) do
    if Process.alive?(pid), do: close.(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
