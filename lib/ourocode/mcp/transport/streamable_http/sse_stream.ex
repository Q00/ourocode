defmodule Ourocode.MCP.Transport.StreamableHTTP.SSEStream do
  @moduledoc """
  Drain and normalize Streamable HTTP event-stream responses.
  """

  alias Ourocode.MCP.Transport.SSE.Parser
  alias Ourocode.MCP.Transport.StreamableHTTP.LifecycleNormalizer
  alias Ourocode.MCP.Transport.StreamableHTTP.RawEvent
  alias Ourocode.MCP.Transport.StreamableHTTP.Response

  @max_buffer_bytes 1_048_576
  @max_response_bytes 8_388_608
  @max_progress_events 2_000

  @spec collect(
          port(),
          integer(),
          [{String.t(), String.t()}],
          binary(),
          keyword(),
          map(),
          map(),
          pos_integer(),
          (Ourocode.MCP.LifecycleEvent.t() -> term())
        ) :: {:ok, map()} | {:error, term()}
  def collect(socket, status, headers, body_rest, options, request, context, timeout, emit_fun)
      when is_function(emit_fun, 1) do
    state = %{
      buffer: body_rest,
      events: [],
      event_count: 0,
      next_event_seq: context.event_seq,
      response: nil,
      content_length: Response.content_length(headers),
      bytes_seen: byte_size(body_rest)
    }

    drain(socket, status, headers, context, options, request, state, timeout, emit_fun)
  end

  @spec parse_complete_frames_with_raw(binary()) ::
          {:ok, [{map(), binary()}], binary()} | {:error, term()}
  def parse_complete_frames_with_raw(buffer) when is_binary(buffer) do
    {frames, rest} = Parser.split_complete_frames(buffer)

    frames
    |> Enum.reduce_while({:ok, []}, fn frame, {:ok, acc} ->
      case Parser.parse_frame(frame) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, event} -> {:cont, {:ok, [{event, frame} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events), rest}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec raw_response_event_payload(map()) :: map()
  def raw_response_event_payload(%{"data" => data} = parsed_event) when is_map(data) do
    data
    |> Map.put(:sse_event_id, Map.get(parsed_event, "id"))
    |> Map.put(:sse_event_type, Map.get(parsed_event, "event"))
  end

  def raw_response_event_payload(%{"metadata" => metadata} = parsed_event)
      when is_map(metadata) do
    metadata
    |> Map.put(:sse_event_id, Map.get(parsed_event, "id"))
    |> Map.put(:sse_event_type, Map.get(parsed_event, "event"))
  end

  def raw_response_event_payload(parsed_event) when is_map(parsed_event), do: parsed_event

  defp drain(socket, status, headers, context, options, request, state, timeout, emit_fun) do
    cond do
      byte_size(state.buffer) > @max_buffer_bytes ->
        {:error, {:sse_frame_too_large, @max_buffer_bytes}}

      state.event_count > @max_progress_events ->
        {:error, {:sse_event_limit_exceeded, @max_progress_events}}

      state.bytes_seen > @max_response_bytes ->
        {:error, {:sse_response_too_large, @max_response_bytes}}

      true ->
        state = emit_complete_frames(status, headers, context, options, state, emit_fun)

        cond do
          state.response ->
            {:ok, state.response}

          state.content_length && state.bytes_seen >= state.content_length ->
            {:ok, state.response || Response.from_sse_events(Enum.reverse(state.events))}

          true ->
            case :gen_tcp.recv(socket, 0, timeout) do
              {:ok, chunk}
              when byte_size(state.buffer) + byte_size(chunk) <= @max_buffer_bytes and
                     state.bytes_seen + byte_size(chunk) <= @max_response_bytes ->
                next_state = %{
                  state
                  | buffer: state.buffer <> chunk,
                    bytes_seen: state.bytes_seen + byte_size(chunk)
                }

                drain(
                  socket,
                  status,
                  headers,
                  context,
                  options,
                  request,
                  next_state,
                  timeout,
                  emit_fun
                )

              {:ok, chunk} when state.bytes_seen + byte_size(chunk) > @max_response_bytes ->
                {:error, {:sse_response_too_large, @max_response_bytes}}

              {:ok, _chunk} ->
                {:error, {:sse_frame_too_large, @max_buffer_bytes}}

              {:error, :closed} ->
                {:ok, state.response || Response.from_sse_events(Enum.reverse(state.events))}

              {:error, reason} ->
                {:error, {:sse_recv_failed, reason}}
            end
        end
    end
  end

  defp emit_complete_frames(status, headers, context, options, state, emit_fun) do
    case parse_complete_frames_with_raw(state.buffer) do
      {:ok, [], rest} ->
        %{state | buffer: rest}

      {:ok, parsed_events, rest} ->
        Enum.reduce(parsed_events, %{state | buffer: rest}, fn {parsed_event, raw_frame}, acc ->
          event_context =
            context
            |> Map.put(:event_seq, acc.next_event_seq)
            |> Map.put(:status, status)
            |> Map.put(:headers, headers)

          {:ok, lifecycle_events} =
            LifecycleNormalizer.normalize_sse_events([parsed_event], event_context)

          response_record =
            RawEvent.build_response_record(
              [
                url: Keyword.get(options, :url),
                status: status,
                headers: headers,
                raw_payload: raw_frame
              ],
              raw_response_event_payload(parsed_event),
              event_context
            )

          lifecycle_events
          |> Enum.map(&RawEvent.annotate_response(&1, response_record))
          |> Enum.each(emit_fun)

          %{
            acc
            | events: [parsed_event | acc.events],
              event_count: acc.event_count + 1,
              next_event_seq: acc.next_event_seq + length(lifecycle_events),
              response: Response.from_parsed_events([parsed_event]) || acc.response
          }
        end)

      {:error, reason} ->
        failed_context =
          context
          |> Map.put(:event_seq, state.next_event_seq)
          |> Map.put(:status, status)
          |> Map.put(:headers, headers)

        response_record =
          RawEvent.build_response_record(
            [
              url: Keyword.get(options, :url),
              status: status,
              headers: headers,
              raw_payload: state.buffer
            ],
            %{},
            failed_context
          )

        failed_context
        |> LifecycleNormalizer.failed(reason)
        |> RawEvent.annotate_response(response_record)
        |> emit_fun.()

        %{state | buffer: "", next_event_seq: state.next_event_seq + 1}
    end
  end
end
