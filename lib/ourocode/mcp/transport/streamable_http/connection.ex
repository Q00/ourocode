defmodule Ourocode.MCP.Transport.StreamableHTTP.Connection do
  @moduledoc """
  TCP/HTTP request helpers for Streamable HTTP transport calls.
  """

  alias Ourocode.Json
  alias Ourocode.MCP.Transport.Http
  alias Ourocode.MCP.Transport.StreamableHTTP.Response
  @max_response_header_bytes 65_536
  @max_response_body_bytes 8_388_608

  @spec connect(URI.t(), pos_integer()) :: {:ok, port()} | {:error, term()}
  def connect(%URI{} = uri, timeout) when is_integer(timeout) and timeout > 0 do
    :gen_tcp.connect(
      String.to_charlist(uri.host),
      uri.port || 80,
      [:binary, packet: :raw, active: false],
      timeout
    )
  end

  @spec httpc_post_json(String.t(), map(), keyword(), pos_integer()) ::
          {:ok, term()} | {:error, term()}
  def httpc_post_json(url, request, options, default_timeout)
      when is_binary(url) and is_map(request) and is_list(options) do
    timeout = Keyword.get(options, :timeout, default_timeout)

    headers =
      [
        {~c"accept", ~c"application/json, text/event-stream"}
      ] ++ Http.charlist_headers(Keyword.get(options, :headers, []))

    body = request |> Json.encode!() |> IO.iodata_to_binary() |> String.to_charlist()

    :httpc.request(
      :post,
      {String.to_charlist(url), headers, ~c"application/json", body},
      [timeout: timeout, connect_timeout: timeout],
      body_format: :binary
    )
  end

  @spec send_stream_request(port(), URI.t(), map(), keyword()) :: :ok | {:error, term()}
  def send_stream_request(socket, %URI{} = uri, request, options)
      when is_port(socket) and is_map(request) and is_list(options) do
    case :gen_tcp.send(socket, stream_request_data(uri, request, options)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:request_send_failed, reason}}
    end
  end

  @doc false
  @spec stream_request_data(URI.t(), map(), keyword()) :: iodata()
  def stream_request_data(%URI{} = uri, request, options)
      when is_map(request) and is_list(options) do
    body = request |> Json.encode!() |> IO.iodata_to_binary()

    request_headers =
      [
        {"host", Http.host_header(uri)},
        {"accept", "application/json, text/event-stream"},
        {"content-type", "application/json"},
        {"content-length", byte_size(body)},
        {"connection", "close"}
      ] ++ Keyword.get(options, :headers, [])

    [
      "POST ",
      Http.request_target(uri),
      " HTTP/1.1\r\n",
      Enum.map(request_headers, fn {key, value} ->
        [to_string(key), ": ", to_string(value), "\r\n"]
      end),
      "\r\n",
      body
    ]
  end

  @spec recv_response_headers(port(), binary(), pos_integer()) ::
          {:ok, integer(), [{String.t(), String.t()}], binary()} | {:error, term()}
  def recv_response_headers(socket, acc, timeout)
      when is_port(socket) and is_binary(acc) and is_integer(timeout) do
    cond do
      byte_size(acc) > @max_response_header_bytes ->
        {:error, {:response_headers_too_large, @max_response_header_bytes}}

      true ->
        case String.split(acc, "\r\n\r\n", parts: 2) do
          [headers_blob, body_rest] when body_rest != nil and headers_blob != acc ->
            with {:ok, status, headers} <- Http.parse_response_headers(headers_blob),
                 :ok <- validate_body_length(headers, body_rest) do
              {:ok, status, headers, body_rest}
            end

          _partial ->
            case :gen_tcp.recv(socket, 0, timeout) do
              {:ok, chunk} when byte_size(acc) + byte_size(chunk) <= @max_response_header_bytes ->
                recv_response_headers(socket, acc <> chunk, timeout)

              {:ok, _chunk} ->
                {:error, {:response_headers_too_large, @max_response_header_bytes}}

              {:error, reason} ->
                {:error, {:response_header_recv_failed, reason}}
            end
        end
    end
  end

  @spec recv_remaining_body(port(), [{term(), term()}], binary(), pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  def recv_remaining_body(socket, headers, body_rest, timeout)
      when is_port(socket) and is_list(headers) and is_binary(body_rest) do
    case Response.content_length(headers) do
      length when is_integer(length) and length > @max_response_body_bytes ->
        {:error, {:response_body_too_large, @max_response_body_bytes}}

      nil when byte_size(body_rest) > @max_response_body_bytes ->
        {:error, {:response_body_too_large, @max_response_body_bytes}}

      nil ->
        recv_until_closed(socket, body_rest, timeout)

      length ->
        recv_until_length(socket, body_rest, length, timeout)
    end
  end

  defp recv_until_length(_socket, body, length, _timeout) when byte_size(body) >= length do
    {:ok, binary_part(body, 0, length)}
  end

  defp recv_until_length(socket, body, length, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, chunk} when byte_size(body) + byte_size(chunk) <= @max_response_body_bytes ->
        recv_until_length(socket, body <> chunk, length, timeout)

      {:ok, _chunk} ->
        {:error, {:response_body_too_large, @max_response_body_bytes}}

      {:error, reason} ->
        {:error, {:body_recv_failed, reason}}
    end
  end

  defp recv_until_closed(socket, body, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, chunk} when byte_size(body) + byte_size(chunk) <= @max_response_body_bytes ->
        recv_until_closed(socket, body <> chunk, timeout)

      {:ok, _chunk} ->
        {:error, {:response_body_too_large, @max_response_body_bytes}}

      {:error, :closed} ->
        {:ok, body}

      {:error, reason} ->
        {:error, {:body_recv_failed, reason}}
    end
  end

  defp validate_body_length(headers, body_rest) do
    case Response.content_length(headers) do
      length when is_integer(length) and length > @max_response_body_bytes ->
        {:error, {:response_body_too_large, @max_response_body_bytes}}

      nil when byte_size(body_rest) > @max_response_body_bytes ->
        {:error, {:response_body_too_large, @max_response_body_bytes}}

      _length ->
        :ok
    end
  end
end
