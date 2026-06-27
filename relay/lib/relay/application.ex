defmodule Relay.Application do
  use Application

  @impl true
  def start(_type, _args) do
    # Task 1: start empty so the app boots. Task 2 adds Relay.Registry,
    # Task 5 adds the TCP/WebSocket listeners.
    children = []
    Supervisor.start_link(children, strategy: :one_for_one, name: Relay.Supervisor)
  end
end
