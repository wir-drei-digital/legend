defmodule Legend.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LegendWeb.Telemetry,
      Legend.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:legend, :ecto_repos), skip: skip_migrations?()},
      Legend.Agents.Supervisor,
      {DNSCluster, query: Application.get_env(:legend, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Legend.PubSub},
      # Start a worker by calling: Legend.Worker.start_link(arg)
      # {Legend.Worker, arg},
      # Start to serve requests, typically the last entry
      LegendWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Legend.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LegendWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # Migrations run only inside a release (web release or desktop sidecar) and
    # can be disabled there via AUTO_MIGRATE=false. Dev/test use mix ecto.setup.
    System.get_env("RELEASE_NAME") == nil or
      not Application.get_env(:legend, :auto_migrate, true)
  end
end
