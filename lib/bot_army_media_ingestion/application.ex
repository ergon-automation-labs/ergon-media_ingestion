defmodule BotArmyMediaIngestion.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if test_env?() do
        []
      else
        [{BotArmyMediaIngestion.NATS.Consumer, []}]
      end

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: BotArmyMediaIngestion.Supervisor
    )
  end

  defp test_env? do
    Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test
  end
end
