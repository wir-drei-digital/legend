defmodule Relay.Application do
  use Application

  # Frozen at compile time (release-safe — no runtime Mix call). In :test the
  # Registry is started per-test via start_supervised!, so the app skips it.
  @start_registry? Mix.env() != :test

  @impl true
  def start(_type, _args) do
    # Task 2 adds Relay.Registry. Task 5 adds the TCP/WebSocket listeners.
    children = if @start_registry?, do: [Relay.Registry], else: []
    Supervisor.start_link(children, strategy: :one_for_one, name: Relay.Supervisor)
  end
end
