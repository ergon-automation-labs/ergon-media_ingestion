defmodule BotArmyMediaIngestion.Application do
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
