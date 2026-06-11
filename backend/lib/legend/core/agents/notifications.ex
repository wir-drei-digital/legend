defmodule Legend.Core.Agents.Notifications do
  @moduledoc "PubSub fan-out for session list changes (consumed by the lobby channel)."

  @topic "sessions:changed"

  def topic, do: @topic

  def sessions_changed do
    Phoenix.PubSub.broadcast(Legend.PubSub, @topic, :sessions_changed)
  end
end
