defmodule BotArmyMediaIngestion.Application do
  @moduledoc "OTP Application for the Media Ingestion bot. Handles YouTube transcripts and audio pipelines."
  use Application

  @env Mix.env()

  @impl true
  def start(_type, _args) do
    # Load config from file (deployed by Salt) into the runtime library's state
    config_data = BotArmyLibraryRuntime.ConfigLoader.load_config()
    Application.put_env(:bot_army_library_runtime, :config_data, config_data)

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
