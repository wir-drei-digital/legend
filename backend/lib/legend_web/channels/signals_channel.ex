defmodule LegendWeb.SignalsChannel do
  @moduledoc """
  Live message timeline for the UI. Join replies with the recent window
  (oldest-first); `message` pushes each new envelope, `read` pushes read ids
  so unread badges stay accurate.
  """

  use LegendWeb, :channel

  alias Legend.Core.Signals
  alias Legend.Core.Signals.Notifications

  @impl true
  def join("signals:timeline", _payload, socket) do
    Phoenix.PubSub.subscribe(Legend.PubSub, Notifications.timeline_topic())

    messages =
      Signals.list_messages!()
      |> Enum.reverse()
      |> Enum.map(&Notifications.summary/1)

    {:ok, %{messages: messages}, socket}
  end

  @impl true
  def handle_info({:signal, summary}, socket) do
    push(socket, "message", summary)
    {:noreply, socket}
  end

  def handle_info({:signals_read, payload}, socket) do
    push(socket, "read", payload)
    {:noreply, socket}
  end
end
