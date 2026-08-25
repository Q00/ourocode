defmodule Ourocode.MCP.Transport.SSE do
  @moduledoc """
  SSE MCP transport connection.

  The process establishes one long-lived `text/event-stream` HTTP connection,
  parses SSE frames as they arrive, and emits journal-ready lifecycle events.
  It owns only transport concerns; higher-level OTP processes own pane state,
  journal persistence, child session mapping, and runtime routing.
  """

  use GenServer

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.Http
  alias Ourocode.MCP.Transport.SSE.Connection
  alias Ourocode.MCP.Transport.SSE.EventEmitter
  alias Ourocode.MCP.Transport.SSE.ParentCall
  alias Ourocode.MCP.Transport.SSE.PendingRequest
  alias Ourocode.MCP.Transport.SSE.RawEvent
  alias Ourocode.MCP.Transport.SSE.State
  alias Ourocode.MCP.Transport.SSE.StreamProcessor

  @max_transport_buffer_bytes 8_388_608
  @default_timeout 5_000

  @type option ::
          {:url, String.t()}
          | {:parent_call_id, String.t()}
          | {:runtime_source, String.t()}
          | {:external_ids, map()}
          | {:event_sink, pid() | (LifecycleEvent.t() -> term())}
          | {:dispatch_url, String.t()}
          | {:headers, [{String.t(), String.t()}]}
          | {:event_seq, non_neg_integer()}
          | {:journal_path, Path.t()}
          | {:raw_payload_store_dir, Path.t()}
          | {:timeout, pos_integer()}
          | {:await_response, boolean()}
          | {:connection_identifier, String.t()}
          | {:session_identifier, String.t()}
          | {:name, GenServer.name()}

  defstruct [
    :socket,
    :event_sink,
    :parent_call_id,
    :runtime_source,
    :external_ids,
    :dispatch_uri,
    :endpoint_url,
    :connection_identifier,
    :session_identifier,
    :request_headers,
    :journal_path,
    :raw_payload_store_dir,
    :status,
    :headers,
    event_seq: 0,
    request_seq: 0,
    pending: %{},
    response_buffer: "",
    sse_buffer: ""
  ]

  @type t :: %__MODULE__{}

  @doc """
  Starts and connects an SSE transport process.

  Required options:
    * `:url` - HTTP SSE endpoint URL

  Useful options:
    * `:event_sink` - pid or one-arity function that receives lifecycle events
    * `:parent_call_id` - local parent call mapping ID
    * `:runtime_source` - external runtime source name
    * `:external_ids` - trusted runtime IDs/status map
    * `:dispatch_url` - HTTP endpoint used to POST parent JSON-RPC requests
    * `:headers` - additional HTTP headers
    * `:journal_path` - JSONL local journal path for persisted lifecycle events
    * `:raw_payload_store_dir` - sidecar directory for raw SSE frame bytes
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  Dispatches a parent MCP JSON-RPC request over the established SSE transport.

  SSE receives server events on the long-lived stream, while JSON-RPC requests
  are posted to the configured message endpoint. Results and progress continue
  to arrive asynchronously through the SSE stream and are emitted as lifecycle
  events.
  """
  @spec call_parent(GenServer.server(), String.t(), map() | list() | nil, keyword()) ::
          {:ok, term()}
          | {:error, term()}
  def call_parent(server, method, params \\ %{}, opts \\ [])
      when is_binary(method) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    GenServer.call(server, {:call_parent, method, params, opts}, timeout + 1_000)
  end

  @doc false
  @spec build_raw_event_record(map(), map()) :: map()
  def build_raw_event_record(%{} = raw_event, context) when is_map(context) do
    RawEvent.build_record(raw_event, context)
  end

  @impl true
  def init(opts) do
    with {:ok, url} <- Keyword.fetch(opts, :url),
         {:ok, uri} <- Http.parse_http_url(url),
         {:ok, socket} <- Connection.connect(uri, Keyword.get(opts, :timeout, @default_timeout)),
         :ok <- Connection.send_request(socket, uri, Keyword.get(opts, :headers, [])) do
      state = State.build(socket, uri, opts)

      :inet.setopts(socket, active: :once)
      {:ok, state}
    else
      :error -> {:stop, {:missing_option, :url}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:call_parent, method, params, opts}, from, state) do
    ParentCall.handle_call(state, from, method, params, opts, @default_timeout)
  end

  @impl true
  def handle_info({:request_timeout, request_id}, state) do
    case PendingRequest.pop(state, request_id) do
      {nil, state} ->
        {:noreply, state}

      {pending, state} ->
        error = {:timeout, request_id}
        GenServer.reply(pending.from, {:error, error})

        state =
          state
          |> EventEmitter.emit(
            :parent_call_failed,
            PendingRequest.failed_event_attrs(request_id, pending, error)
          )

        {:noreply, state}
    end
  end

  def handle_info({:tcp, socket, chunk}, %{socket: socket, status: nil} = state) do
    if byte_size(state.response_buffer) + byte_size(chunk) > @max_transport_buffer_bytes do
      {:stop, {:response_buffer_too_large, @max_transport_buffer_bytes},
       fail_pending(state, :response_buffer_too_large)}
    else
      state =
        StreamProcessor.process_response_chunk(%{
          state
          | response_buffer: state.response_buffer <> chunk
        })

      :inet.setopts(socket, active: :once)
      {:noreply, state}
    end
  end

  def handle_info({:tcp, socket, chunk}, %{socket: socket} = state) do
    if byte_size(state.sse_buffer) + byte_size(chunk) > @max_transport_buffer_bytes do
      {:stop, {:sse_buffer_too_large, @max_transport_buffer_bytes},
       fail_pending(state, :sse_buffer_too_large)}
    else
      state = StreamProcessor.process_sse_chunk(%{state | sse_buffer: state.sse_buffer <> chunk})
      :inet.setopts(socket, active: :once)
      {:noreply, state}
    end
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    {:stop, :normal,
     state |> fail_pending(:transport_closed) |> EventEmitter.emit(:transport_closed, %{})}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    {:stop, reason,
     state |> fail_pending(reason) |> EventEmitter.emit(:transport_failed, %{error: reason})}
  end

  @impl true
  def terminate(_reason, %{socket: socket}) when is_port(socket) do
    :gen_tcp.close(socket)
    :ok
  end

  defp fail_pending(state, reason) do
    Enum.reduce(state.pending, PendingRequest.clear(state), fn {request_id, pending}, acc ->
      Process.cancel_timer(pending.timer)
      GenServer.reply(pending.from, {:error, reason})

      EventEmitter.emit(
        acc,
        :parent_call_failed,
        PendingRequest.failed_event_attrs(request_id, pending, reason)
      )
    end)
  end

  @doc false
  @spec raw_payload_path(Path.t(), String.t()) :: Path.t()
  def raw_payload_path(store_dir, "sha256:" <> digest) when is_binary(store_dir) do
    RawEvent.raw_payload_path(store_dir, "sha256:" <> digest)
  end

  @doc false
  @spec canonical_journal_event(LifecycleEvent.t() | map()) :: map()
  def canonical_journal_event(event), do: RawEvent.canonical_journal_event(event)
end
