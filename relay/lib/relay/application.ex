defmodule Relay.Application do
  use Application
  require Logger

  # Frozen at compile time (release-safe — no runtime Mix call). In :test the
  # Registry is started per-test via start_supervised!, so the app skips it.
  @start_registry? Mix.env() != :test

  @impl true
  def start(_type, _args) do
    children = registry_children() ++ listener_children()
    Supervisor.start_link(children, strategy: :one_for_one, name: Relay.Supervisor)
  end

  defp registry_children, do: if(@start_registry?, do: [Relay.Registry], else: [])

  # Master gate: tests set :start_listeners false (config/test.exs) and open the
  # carrier listener themselves on an ephemeral port. Dev/prod default to true.
  defp listener_children do
    if Application.get_env(:relay, :start_listeners, true) do
      [carrier_listener() | device_listeners()]
    else
      []
    end
  end

  # The instance dials this over WS (TLS terminated upstream — scheme: :http here)
  # and registers {handle, secret}; thereafter it is the mux hub for that handle.
  defp carrier_listener do
    {Bandit,
     plug: Relay.CarrierPlug, scheme: :http, port: Application.get_env(:relay, :carrier_port)}
  end

  # The device endpoint terminates TLS, so it needs a cert/key. Without them
  # (e.g. a dev box with no RELAY_CERTFILE) we skip it rather than crash the
  # node — the carrier still boots. Real TLS byte-splicing is the manual live path.
  defp device_listeners do
    certfile = Application.get_env(:relay, :certfile)
    keyfile = Application.get_env(:relay, :keyfile)

    if certfile && keyfile do
      [
        {ThousandIsland,
         port: Application.get_env(:relay, :device_port),
         handler_module: Relay.Device,
         transport_module: ThousandIsland.Transports.SSL,
         transport_options: [certfile: certfile, keyfile: keyfile]}
      ]
    else
      Logger.warning("Relay device listener disabled: RELAY_CERTFILE/RELAY_KEYFILE not set")
      []
    end
  end
end
