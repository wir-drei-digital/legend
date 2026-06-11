defmodule Legend.Core.Signals do
  @moduledoc """
  The signal bus: agent-to-agent and human-to-agent messages, the per-session
  inbox, and the JSON:API surface at /api/messages.
  """

  use Ash.Domain, otp_app: :legend, extensions: [AshJsonApi.Domain]

  json_api do
    routes do
      base_route "/messages", Legend.Core.Signals.Message do
        index :list
        post :send_as_human
      end
    end
  end

  resources do
    resource Legend.Core.Signals.Message do
      define :send_message, action: :send
      define :send_human_message, action: :send_as_human
      define :list_messages, action: :list
      define :unread_messages, action: :unread_for, args: [:session_id]
      define :mark_message_read, action: :mark_read
    end
  end

  @doc """
  Drains a session's inbox: returns unread messages oldest-first, marks them
  read, and broadcasts the read ids so UI unread badges update.
  """
  def read_inbox!(session_id) do
    case unread_messages!(session_id) do
      [] ->
        []

      messages ->
        read = Enum.map(messages, &mark_message_read!/1)
        Legend.Core.Signals.Notifications.messages_read(session_id, Enum.map(read, & &1.id))
        read
    end
  end
end
