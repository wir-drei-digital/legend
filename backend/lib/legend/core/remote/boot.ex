defmodule Legend.Core.Remote.Boot do
  @moduledoc """
  Applies the `remote_access` bind to the endpoint config BEFORE the Endpoint
  child starts. Runs sync in `start_link` (the `Library.Seeder` pattern) and
  returns `:ignore` — no process stays alive. Disabled = no-op (loopback).
  """
  require Logger

  alias Legend.Core.Remote

  def start_link(_opts) do
    :ok = apply!()
    :ignore
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient
    }
  end

  @spec apply!() :: :ok
  def apply! do
    config = Remote.config()

    if config.enabled do
      existing = Application.get_env(:legend, LegendWeb.Endpoint, [])

      Application.put_env(
        :legend,
        LegendWeb.Endpoint,
        Remote.endpoint_overrides(existing, config)
      )

      Logger.info(
        "[remote] remote access ENABLED — endpoint bound 0.0.0.0 (host: #{config.host})"
      )
    end

    :ok
  end
end
