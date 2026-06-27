defmodule Legend.Federation.Supervisor do
  @moduledoc """
  Boots the relay-ingress endpoint and its federation carrier when, and only
  when, remote access runs "via relay". Both are long-lived processes and live
  here under a supervisor rather than as an inline branch in `Legend.Application`.

  Why a supervisor and not an inline `if` in the top-level children list:
  `Remote.relay_ingress_enabled?/0` reads the persisted `remote_access` setting
  from SQLite, and that read is only valid once `Legend.Repo` is started — which
  happens *after* the top-level children list is built. This child's `init/1`
  runs after the Repo (and after `Legend.Core.Remote.Boot` has set the ingress
  `check_origin`/`url`), so reading the setting here is safe.

  Disabled (the default) ⇒ zero children ⇒ no behavior change.
  """
  use Supervisor

  alias Legend.Core.Remote

  @default_ingress_port 4808

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: Supervisor.init(children(), strategy: :one_for_one)

  defp children do
    if Remote.relay_ingress_enabled?() do
      c = Remote.config()

      [
        LegendWeb.RelayIngressEndpoint,
        {Legend.Federation.RelayClient,
         %{
           relay_url: c.relay_url,
           handle: c.relay_handle,
           secret: c.relay_secret,
           target_port: ingress_port()
         }}
      ]
    else
      []
    end
  end

  # The carrier splices relayed streams to the ingress endpoint's fixed loopback
  # port (Part-1), so they arrive `via_relay`-stamped.
  defp ingress_port do
    :legend
    |> Application.get_env(LegendWeb.RelayIngressEndpoint, [])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port, @default_ingress_port)
  end
end
