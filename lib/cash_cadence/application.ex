defmodule CashCadence.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CashCadenceWeb.Telemetry,
      CashCadence.Repo,
      {DNSCluster, query: Application.get_env(:cash_cadence, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: CashCadence.PubSub},
      # Start a worker by calling: CashCadence.Worker.start_link(arg)
      # {CashCadence.Worker, arg},
      # Start to serve requests, typically the last entry
      CashCadenceWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CashCadence.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CashCadenceWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
