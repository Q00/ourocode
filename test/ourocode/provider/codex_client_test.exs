defmodule Ourocode.Provider.Codex.ClientTest do
  use ExUnit.Case, async: false

  alias Ourocode.Provider.Codex.Client

  test "default_model uses the ChatGPT Codex supported model name" do
    previous = System.get_env("OUROCODE_CODEX_MODEL")
    System.delete_env("OUROCODE_CODEX_MODEL")

    on_exit(fn ->
      if previous,
        do: System.put_env("OUROCODE_CODEX_MODEL", previous),
        else: System.delete_env("OUROCODE_CODEX_MODEL")
    end)

    assert Client.default_model() == "gpt-5.5"
  end

  test "default_model can be overridden for provider migrations" do
    previous = System.get_env("OUROCODE_CODEX_MODEL")
    System.put_env("OUROCODE_CODEX_MODEL", " custom-codex-model ")

    on_exit(fn ->
      if previous,
        do: System.put_env("OUROCODE_CODEX_MODEL", previous),
        else: System.delete_env("OUROCODE_CODEX_MODEL")
    end)

    assert Client.default_model() == "custom-codex-model"
  end

  test "stream_request_body resolves explicit env configured and fallback model precedence" do
    previous = System.get_env("OUROCODE_CODEX_MODEL")
    System.put_env("OUROCODE_CODEX_MODEL", " env-codex-model ")

    on_exit(fn ->
      if previous,
        do: System.put_env("OUROCODE_CODEX_MODEL", previous),
        else: System.delete_env("OUROCODE_CODEX_MODEL")
    end)

    assert Client.stream_request_body("hello", [model: " explicit-codex-model "], "sys")[
             "model"
           ] == "explicit-codex-model"

    assert Client.stream_request_body("hello", [configured_model: "gpt-5.3-codex"], "sys")[
             "model"
           ] == "env-codex-model"

    assert Client.stream_request_body(
             "hello",
             [model: "gpt-5.3-codex", model_source: :session],
             "sys"
           )["model"] == "env-codex-model"

    System.put_env("OUROCODE_CODEX_MODEL", "  ")

    assert Client.stream_request_body(
             "hello",
             [model: " gpt-5.3-codex ", model_source: :session],
             "sys"
           )["model"] == "gpt-5.3-codex"

    assert Client.stream_request_body("hello", [configured_model: " gpt-5.3-codex "], "sys")[
             "model"
           ] == "gpt-5.3-codex"

    assert Client.stream_request_body("hello", [configured_model: "  "], "sys")["model"] ==
             "gpt-5.5"
  end

  test "request_body builds the Responses API user turn" do
    body = Client.request_body("hello", "gpt-5.3-codex", "sys")

    assert body["model"] == "gpt-5.3-codex"
    assert body["instructions"] == "sys"
    assert body["stream"] == true
    assert body["store"] == false

    assert body["input"] == [
             %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "hello"}]}
           ]
  end

  test "text_delta extracts only output_text deltas" do
    assert Client.text_delta(%{"type" => "response.output_text.delta", "delta" => "Hi"}) == "Hi"
    assert Client.text_delta(%{"type" => "response.created"}) == nil
    assert Client.text_delta(%{"type" => "response.output_text.delta"}) == nil
  end

  test "terminal? detects completion events" do
    assert Client.terminal?(%{"type" => "response.completed"})
    assert Client.terminal?(%{"type" => "response.failed"})
    refute Client.terminal?(%{"type" => "response.output_text.delta"})
  end

  test "parse_sse splits complete frames and keeps a partial tail" do
    chunk =
      ~s(data: {"type":"response.output_text.delta","delta":"He"}\n\n) <>
        ~s(data: {"type":"response.output_text.delta","delta":"llo"}\n\n) <>
        ~s(data: {"type":"response.comp)

    {events, rest} = Client.parse_sse(chunk)

    assert Enum.map(events, &Client.text_delta/1) == ["He", "llo"]
    assert rest == ~s(data: {"type":"response.comp)

    {events2, rest2} = Client.parse_sse(rest <> ~s(leted"}\n\n))
    assert Enum.any?(events2, &Client.terminal?/1)
    assert rest2 == ""
  end

  test "parse_sse ignores [DONE] and non-data lines" do
    chunk = "event: ping\ndata: [DONE]\n\ndata: {\"type\":\"response.created\"}\n\n"
    {events, ""} = Client.parse_sse(chunk)
    assert events == [%{"type" => "response.created"}]
  end

  test "stream returns not_signed_in without credentials" do
    tmp_home =
      Path.join(System.tmp_dir!(), "ourocode-no-auth-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_home)
    original = System.get_env("HOME")
    System.put_env("HOME", tmp_home)

    on_exit(fn ->
      if original, do: System.put_env("HOME", original)
      File.rm_rf(tmp_home)
    end)

    assert {:error, :not_signed_in} = Client.stream("hi", [], fn _ -> :ok end)
  end
end
