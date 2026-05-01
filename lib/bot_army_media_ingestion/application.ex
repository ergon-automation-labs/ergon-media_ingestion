defmodule BotArmyMediaIngestion.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Mix.env() == :test do
        []
      else
        [{BotArmyMediaIngestion.NATS.Consumer, []}]
      end

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: BotArmyMediaIngestion.Supervisor
    )
  end
end
