defmodule Ourocode.MCP.Transport.StreamableHTTP.Session do
  @moduledoc """
  Performs the optional MCP Streamable HTTP session handshake.
  """

  alias Ourocode.Json

  @spec ensure(String.t(), keyword(), String.t(), pos_integer()) :: {:ok, keyword()}
  def ensure(url, options, protocol_version, default_timeout)
      when is_binary(url) and is_list(options) do
    cond do
      not Keyword.get(options, :mcp_session, false) ->
        {:ok, options}

      has_header?(options, "mcp-session-id") ->
        {:ok, options}

      true ->
        with {:ok, session_id} <- initialize(url, options, protocol_version, default_timeout),
             :ok <- initialized(url, session_id, options, protocol_version, default_timeout) do
          {:ok, put_session_headers(options, session_id, protocol_version)}
        else
          _no_session -> {:ok, options}
        end
    end
  end

  @spec open_owned(String.t(), keyword(), String.t(), pos_integer()) ::
          {:ok, keyword(), boolean()}
  def open_owned(url, options, protocol_version, default_timeout) do
    existing? = has_header?(options, "mcp-session-id")

    case ensure(url, options, protocol_version, default_timeout) do
      {:ok, ensured} ->
        owned? = not existing? and has_header?(ensured, "mcp-session-id")
        {:ok, ensured, owned?}
    end
  end

  @spec terminate(String.t(), keyword(), pos_integer()) :: :ok
  def terminate(url, options, default_timeout) when is_binary(url) and is_list(options) do
    case options |> Keyword.get(:headers, []) |> header_value("mcp-session-id") do
      nil ->
        :ok

      session_id ->
        timeout = Keyword.get(options, :timeout, default_timeout)

        headers = [
          {~c"mcp-session-id", String.to_charlist(session_id)},
          {~c"mcp-protocol-version",
           String.to_charlist(
             header_value(Keyword.get(options, :headers, []), "mcp-protocol-version") ||
               "2025-06-18"
           )}
        ]

        _ =
          :httpc.request(
            :delete,
            {String.to_charlist(url), headers},
            [timeout: timeout, connect_timeout: timeout],
            body_format: :binary
          )

        :ok
    end
  rescue
    _exception -> :ok
  end

  @spec has_header?(keyword(), String.t()) :: boolean()
  def has_header?(options, name) when is_list(options) and is_binary(name) do
    normalized_name = String.downcase(name)

    options
    |> Keyword.get(:headers, [])
    |> Enum.any?(fn {key, _value} -> String.downcase(to_string(key)) == normalized_name end)
  end

  @spec header_value([{term(), term()}], String.t()) :: String.t() | nil
  def header_value(headers, name) when is_list(headers) and is_binary(name) do
    normalized_name = String.downcase(name)

    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == normalized_name, do: to_string(value)
    end)
  end

  @spec put_session_headers(keyword(), String.t(), String.t()) :: keyword()
  def put_session_headers(options, session_id, protocol_version)
      when is_list(options) and is_binary(session_id) and is_binary(protocol_version) do
    session_headers = [
      {"mcp-session-id", session_id},
      {"mcp-protocol-version", protocol_version}
    ]

    Keyword.put(options, :headers, session_headers ++ Keyword.get(options, :headers, []))
  end

  defp initialize(url, options, protocol_version, default_timeout) do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => "ourocode-init",
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => protocol_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "ourocode", "version" => "0.1.0"}
      }
    }

    case post(url, payload, [], options, default_timeout) do
      {:ok, status, headers, _body} when status in 200..299 ->
        case header_value(headers, "mcp-session-id") do
          nil -> {:error, :mcp_session_id_missing}
          id -> {:ok, id}
        end

      {:ok, status, _headers, body} ->
        {:error, {:mcp_initialize_failed, status, body}}

      {:error, reason} ->
        {:error, {:mcp_initialize_request_failed, reason}}
    end
  end

  defp initialized(url, session_id, options, protocol_version, default_timeout) do
    payload = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized",
      "params" => %{}
    }

    extra = [
      {~c"mcp-session-id", String.to_charlist(session_id)},
      {~c"mcp-protocol-version", String.to_charlist(protocol_version)}
    ]

    case post(url, payload, extra, options, default_timeout) do
      {:ok, status, _headers, _body} when status in 200..299 -> :ok
      {:ok, status, _headers, body} -> {:error, {:mcp_initialized_failed, status, body}}
      {:error, reason} -> {:error, {:mcp_initialized_request_failed, reason}}
    end
  end

  defp post(url, payload, extra_headers, options, default_timeout) do
    timeout = Keyword.get(options, :timeout, default_timeout)

    headers =
      [{~c"accept", ~c"application/json, text/event-stream"}] ++ extra_headers

    body = payload |> Json.encode!() |> IO.iodata_to_binary() |> String.to_charlist()

    case :httpc.request(
           :post,
           {String.to_charlist(url), headers, ~c"application/json", body},
           [timeout: timeout, connect_timeout: timeout],
           body_format: :binary
         ) do
      {:ok, {{_, status, _reason}, resp_headers, resp_body}} ->
        {:ok, status, resp_headers, resp_body}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
