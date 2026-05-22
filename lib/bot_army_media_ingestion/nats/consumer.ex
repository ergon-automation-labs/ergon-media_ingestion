defmodule BotArmyMediaIngestion.NATS.Consumer do
  @moduledoc "NATS consumer for media ingestion requests (YouTube transcripts, audio)."
  use GenServer
  require Logger

  alias BotArmyMediaIngestion.YouTube.Transcript

  @registry_heartbeat_ms 20_000
  @subject "media.ingestion.youtube.transcript.get"

  @subjects [
    %{
      subject: @subject,
      type: :request_reply,
      description: "Fetch YouTube transcript and metadata"
    }
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    with {:ok, conn} <- GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5_000),
         {:ok, sub} <- Gnat.sub(conn, self(), @subject) do
      BotArmyRuntime.Registry.register("media_ingestion", @subjects, app_version())
      Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)

      {:ok, %{conn: conn, sub: sub, registry_registered?: true}}
    else
      {:error, reason} ->
        Logger.error("[MediaIngestion] NATS startup failed: #{inspect(reason)}")
        {:stop, :nats_startup_failed}
    end
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    BotArmyRuntime.Tracing.with_consumer_span(msg.topic, Map.get(msg, :headers, []), fn ->
      params = decode_payload(msg.body)

      response =
        case Transcript.fetch(params) do
          {:ok, data} -> BotArmyRuntime.NATS.Reply.ok(data)
          {:error, reason} -> BotArmyRuntime.NATS.Reply.error(reason, :validation_error)
        end

      send_reply(msg.reply_to, response)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:registry_heartbeat, state) do
    if state.registry_registered? do
      BotArmyRuntime.Registry.register("media_ingestion", @subjects, app_version())
      Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp decode_payload(body) when is_binary(body) do
    case BotArmyCore.NATS.Decoder.decode(body) do
      {:ok, %{"payload" => payload}} when is_map(payload) ->
        payload

      {:ok, decoded} when is_map(decoded) ->
        decoded

      _ ->
        case Jason.decode(body) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> %{}
        end
    end
  end

  defp send_reply(nil, _response), do: :ok

  defp send_reply(reply_to, response) do
    payload =
      cond do
        is_binary(response) -> response
        is_map(response) -> Jason.encode!(response)
        true -> to_string(response)
      end

    with {:ok, conn} <- GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5_000) do
      headers = BotArmyRuntime.Tracing.inject_trace_context([])
      Gnat.pub(conn, reply_to, payload, headers: headers)
    end
  end

  defp app_version do
    case Application.spec(:bot_army_media_ingestion, :vsn) do
      nil -> "unknown"
      vsn when is_list(vsn) -> to_string(vsn)
      vsn -> "#{vsn}"
    end
  end
end
