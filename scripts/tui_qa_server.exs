defmodule Ourocode.TuiQaServer do
  @moduledoc false

  @root File.cwd!()
  @ui_dir Path.join(@root, "docs/tui-qa")

  def run(argv) do
    port = port_from(argv)
    {:ok, socket} = :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true])
    url = "http://127.0.0.1:#{port}/"
    IO.puts("TUI QA server: #{url}")
    IO.puts("Frames: #{url}frames.json")
    accept(socket)
  end

  defp port_from(argv) do
    case Enum.find_index(argv, &(&1 == "--port")) do
      nil -> env_port()
      index -> argv |> Enum.at(index + 1, "") |> parse_port(env_port())
    end
  end

  defp env_port do
    System.get_env("TUI_QA_PORT", "5199") |> parse_port(5199)
  end

  defp parse_port(value, fallback) do
    case Integer.parse(to_string(value)) do
      {port, ""} when port > 0 and port < 65_536 -> port
      _other -> fallback
    end
  end

  defp accept(socket) do
    {:ok, client} = :gen_tcp.accept(socket)
    serve(client)
    accept(socket)
  end

  defp serve(client) do
    request = read_request(client)
    {path, _query} = request_path(request)
    {status, headers, body} = response(path)
    :ok = :gen_tcp.send(client, http_response(status, headers, body))
    :gen_tcp.close(client)
  rescue
    _exception ->
      :gen_tcp.close(client)
  end

  defp read_request(client) do
    case :gen_tcp.recv(client, 0, 2_000) do
      {:ok, data} -> data
      {:error, _reason} -> ""
    end
  end

  defp request_path(request) do
    request
    |> String.split("\r\n", parts: 2)
    |> List.first("")
    |> String.split(" ")
    |> case do
      [_method, target, _version] -> URI.parse(target)
      _other -> URI.parse("/")
    end
    |> then(&{normalize_path(&1.path), &1.query})
  end

  defp normalize_path(nil), do: "/"
  defp normalize_path(""), do: "/"
  defp normalize_path(path), do: URI.decode(path)

  defp response("/health"), do: {200, [{"content-type", "text/plain; charset=utf-8"}], "ok"}

  defp response("/frames.json") do
    {200, [{"content-type", "application/json; charset=utf-8"}], Ourocode.Terminal.QaFrames.all_json()}
  end

  defp response(path) do
    file_path = static_path(path)

    if File.regular?(file_path) do
      {200, [{"content-type", content_type(file_path)}], File.read!(file_path)}
    else
      {404, [{"content-type", "text/plain; charset=utf-8"}], "not found"}
    end
  end

  defp static_path("/"), do: Path.join(@ui_dir, "index.html")

  defp static_path(path) do
    safe =
      path
      |> String.trim_leading("/")
      |> Path.expand("/")
      |> Path.relative_to("/")

    Path.join(@ui_dir, safe)
  end

  defp content_type(path) do
    case Path.extname(path) do
      ".html" -> "text/html; charset=utf-8"
      ".css" -> "text/css; charset=utf-8"
      ".js" -> "text/javascript; charset=utf-8"
      ".json" -> "application/json; charset=utf-8"
      ".svg" -> "image/svg+xml"
      ".png" -> "image/png"
      _other -> "application/octet-stream"
    end
  end

  defp http_response(status, headers, body) do
    body = IO.iodata_to_binary(body)
    reason = if status == 200, do: "OK", else: "Not Found"

    header_lines =
      headers
      |> Enum.concat([{"content-length", byte_size(body)}, {"connection", "close"}])
      |> Enum.map(fn {key, value} -> "#{key}: #{value}\r\n" end)

    ["HTTP/1.1 #{status} #{reason}\r\n", header_lines, "\r\n", body]
  end
end

Ourocode.TuiQaServer.run(System.argv())

