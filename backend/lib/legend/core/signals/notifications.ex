defmodule Legend.Core.Signals.Notifications do
  @moduledoc """
  PubSub fan-out for the signal bus. `inbox:<session_id>` drives the per-session
  nudge; the `signals` topic drives the live UI timeline. Messages created
  already-read (audit records delivered out of band, e.g. handoff-at-launch)
  skip the inbox broadcast.
  """

  @timeline "signals"

  def timeline_topic, do: @timeline
  def inbox_topic(session_id), do: "inbox:#{session_id}"

  def message_created(%{read_at: %DateTime{}} = message) do
    broadcast(@timeline, {:signal, summary(message)})
  end

  def message_created(message) do
    summary = summary(message)
    broadcast(inbox_topic(message.to_session_id), {:new_message, summary})
    broadcast(@timeline, {:signal, summary})
  end

  def messages_read(session_id, ids) do
    broadcast(@timeline, {:signals_read, %{session_id: session_id, ids: ids}})
  end

  @doc "Wire-format map for channel payloads and broadcasts."
  def summary(message) do
    %{
      id: message.id,
      from_session_id: message.from_session_id,
      from_label: from_label(message.from_session_id),
      to_session_id: message.to_session_id,
      kind: message.kind,
      payload: message.payload,
      read_at: message.read_at,
      inserted_at: message.inserted_at
    }
  end

  defp from_label(nil), do: "human"

  defp from_label(session_id) do
    case Legend.Core.Agents.get_session(session_id) do
      {:ok, session} -> session.name || session.harness_id
      {:error, _} -> "unknown"
    end
  end

  defp broadcast(topic, payload) do
    Phoenix.PubSub.broadcast(Legend.PubSub, topic, payload)
  end
end
