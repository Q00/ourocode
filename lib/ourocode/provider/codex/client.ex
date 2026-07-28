defmodule Ourocode.Provider.Codex.Client do
  @moduledoc """
  Streams a main-session turn through the ChatGPT Codex Responses endpoint.

  Uses the OAuth access token from `Ourocode.Provider.Codex` and the same
  `backend-api/codex/responses` endpoint + OpenAI Responses API shape that
  Codex CLI / opencode use. Streaming is done with `:httpc` async delivery so
  no extra dependency is needed; the SSE frame parser is pure and unit-tested.
  """

  alias Ourocode.Json
  alias Ourocode.Provider.Codex
  alias Ourocode.Provider.Codex.Responses

  @endpoint "https://chatgpt.com/backend-api/codex/responses"
  @default_model "gpt-5.5"

  @doc "Returns the ChatGPT Codex model used when no explicit model is passed."
  @spec default_model() :: String.t()
  def default_model, do: env_model() || @default_model

  @doc """
  Builds the OpenAI Responses API request body using stream model precedence.

  Precedence is explicit unmarked `opts[:model]`, `OUROCODE_CODEX_MODEL`,
  session/config model (`opts[:model]` with `model_source: :session` or
  `opts[:configured_model]`), then the built-in Codex fallback.
  """
  @spec stream_request_body(String.t(), keyword(), String.t()) :: map()
  def stream_request_body(prompt, opts, instructions)
      when is_binary(prompt) and is_list(opts) and is_binary(instructions) do
    model = stream_model(opts)

    case Keyword.get(opts, :input) do
      input when is_list(input) and input != [] ->
        Responses.request_body_for_input(input, model, instructions)

      _none ->
        request_body(prompt, model, instructions)
    end
  end

  @doc """
  Streams `prompt`, invoking `on_chunk.(text)` for each output delta.

  Returns `{:ok, full_text}` on completion, `{:error, :not_signed_in}` when
  there is no Codex session, or `{:error, reason}` on a transport/API failure.
  """
  @spec stream(String.t(), keyword(), (String.t() -> any())) ::
          {:ok, String.t()} | {:error, term()}
  def stream(prompt, opts \\ [], on_chunk) when is_binary(prompt) and is_function(on_chunk, 1) do
    case Codex.authorization() do
      {:ok, %{access: access, account_id: account_id}} ->
        session_id = Keyword.get(opts, :session_id, "ourocode-main")
        instructions = Keyword.get(opts, :instructions, Ourocode.Prompt.system())

        # `opts[:input]` carries prepared multi-turn input items (history +
        # current message); without it the prompt is a single user turn.
        body = stream_request_body(prompt, opts, instructions)

        headers = httpc_headers(Codex.api_headers(access, account_id, session_id))

        do_stream(headers, body, on_chunk)

      :error ->
        {:error, :not_signed_in}
    end
  end

  @doc """
  Builds the OpenAI Responses API request body for a single user turn.
  """
  @spec request_body(String.t(), String.t(), String.t()) :: map()
  defdelegate request_body(prompt, model, instructions), to: Responses

  @doc """
  Parses accumulated SSE bytes into `{events, rest}`.

  `events` are decoded JSON maps from `data:` lines (excluding the `[DONE]`
  sentinel); `rest` is an unterminated trailing frame for the next chunk.
  """
  @spec parse_sse(binary()) :: {[map()], binary()}
  defdelegate parse_sse(buffer), to: Responses

  @doc """
  Extracts the streamed text delta from a Responses API event, if any.
  """
  @spec text_delta(map()) :: String.t() | nil
  defdelegate text_delta(event), to: Responses

  @doc "True for the terminal Responses stream events."
  @spec terminal?(map()) :: boolean()
  defdelegate terminal?(event), to: Responses

  # --- internals -----------------------------------------------------------

  defp do_stream(headers, body_map, on_chunk) do
    _ = Application.ensure_all_started(:ssl)
    _ = Application.ensure_all_started(:inets)
    body = body_map |> Json.encode!() |> IO.iodata_to_binary()

    request =
      {String.to_charlist(@endpoint), headers, ~c"application/json", body}

    case :httpc.request(
           :post,
           request,
           [timeout: 120_000, connect_timeout: 20_000],
           sync: false,
           stream: :self,
           body_format: :binary
         ) do
      {:ok, request_id} ->
        receive_stream(request_id, "", [], on_chunk)

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp receive_stream(request_id, buffer, acc, on_chunk) do
    receive do
      {:http, {^request_id, :stream_start, _headers}} ->
        receive_stream(request_id, buffer, acc, on_chunk)

      {:http, {^request_id, :stream, chunk}} ->
        {events, rest} = Responses.parse_sse(buffer <> chunk)
        acc = Enum.reduce(events, acc, &handle_event(&1, &2, on_chunk))
        receive_stream(request_id, rest, acc, on_chunk)

      {:http, {^request_id, :stream_end, _headers}} ->
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

      {:http, {^request_id, {{_v, status, _r}, _headers, resp_body}}} ->
        {:error, {:api_error, status, truncate(resp_body)}}

      {:http, {^request_id, {:error, reason}}} ->
        {:error, {:http_error, reason}}
    after
      120_000 ->
        :httpc.cancel_request(request_id)
        {:error, :timeout}
    end
  end

  defp handle_event(event, acc, on_chunk) do
    cond do
      delta = Responses.text_delta(event) ->
        on_chunk.(delta)
        [delta | acc]

      Responses.terminal?(event) ->
        acc

      true ->
        acc
    end
  end

  defp httpc_headers(headers) do
    Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  defp stream_model(opts) do
    opts
    |> model_candidates()
    |> Enum.find_value(&present_model/1)
  end

  defp model_candidates(opts) do
    if Keyword.get(opts, :model_source) == :session do
      [
        env_model(),
        Keyword.get(opts, :model),
        Keyword.get(opts, :configured_model),
        @default_model
      ]
    else
      [
        Keyword.get(opts, :model),
        env_model(),
        Keyword.get(opts, :configured_model),
        @default_model
      ]
    end
  end

  defp env_model, do: present_model(System.get_env("OUROCODE_CODEX_MODEL"))

  defp present_model(model) when is_binary(model) do
    case String.trim(model) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_model(_model), do: nil

  defp truncate(body) when is_binary(body), do: String.slice(body, 0, 300)
  defp truncate(_body), do: ""
end
