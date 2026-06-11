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
end
