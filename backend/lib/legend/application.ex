defmodule Legend.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    base_children = [
      LegendWeb.Telemetry,
      Legend.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:legend, :ecto_repos), skip: skip_migrations?()},
      # After the Migrator so the settings table is readable for root
      # resolution; a bad root raises here and aborts boot loudly.
      Legend.Core.Library.Seeder,
      # Applies the remote_access bind to the endpoint config before it starts
      # (Repo is up so the setting is readable). No-op when disabled (loopback).
      Legend.Core.Remote.Boot,
      {DNSCluster, query: Application.get_env(:legend, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Legend.PubSub},
      Legend.Core.Agents.Supervisor,
      # Start a worker by calling: Legend.Worker.start_link(arg)
      # {Legend.Worker, arg},
      # Start to serve requests, typically the last entry
      LegendWeb.Endpoint
    ]

    # The relay ingress is a separate `server: false` endpoint that only boots
    # when remote access runs "via relay" (Part 2). Default off ⇒ not started ⇒
    # zero behavior change.
    children =
      base_children ++
        if Legend.Core.Remote.relay_ingress_enabled?(),
          do: [LegendWeb.RelayIngressEndpoint],
          else: []

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
    # Dev/test (Mix present) manage the schema via mix ecto.setup. Releases
    # (web release or Burrito desktop sidecar — neither ships Mix) migrate on
    # boot unless AUTO_MIGRATE=false. Don't key this on RELEASE_NAME: the
    # Burrito launcher doesn't set it.
    Code.ensure_loaded?(Mix) or not Application.get_env(:legend, :auto_migrate, true)
  end
end
