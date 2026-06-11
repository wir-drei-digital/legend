defmodule LegendWeb.SessionsLobbyChannel do
  @moduledoc "Notifies clients that the session list changed (they refetch via REST)."

  use LegendWeb, :channel

  @impl true
  def join("sessions:lobby", _payload, socket) do
    Phoenix.PubSub.subscribe(Legend.PubSub, Legend.Agents.Notifications.topic())
    {:ok, socket}
  end

  @impl true
  def handle_info(:sessions_changed, socket) do
    push(socket, "changed", %{})
    {:noreply, socket}
  end
end
