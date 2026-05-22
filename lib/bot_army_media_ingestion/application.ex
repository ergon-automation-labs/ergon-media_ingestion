defmodule BotArmyMediaIngestion.Application do
  @moduledoc "OTP Application for the Media Ingestion bot. Handles YouTube transcripts and audio pipelines."
  use Application

  @env Mix.env()

  @impl true
  def start(_type, _args) do
    children =
      if @env == :test do
        []
      else
        [{BotArmyMediaIngestion.PulsePublisher, []}, {BotArmyMediaIngestion.NATS.Consumer, []}]
      end

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: BotArmyMediaIngestion.Supervisor
    )
  end
end
