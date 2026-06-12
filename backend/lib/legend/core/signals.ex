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

      # Not atomic — partial progress on raise; the consumer re-drains on retry.
      messages ->
        read = Enum.map(messages, &mark_message_read!/1)
        Legend.Core.Signals.Notifications.messages_read(session_id, Enum.map(read, & &1.id))
        read
    end
  end

  @doc "Launch-context primer teaching an agent its identity and the messaging tools."
  def messaging_primer(session) do
    spawner =
      case session.spawned_by_session_id do
        nil ->
          ""

        id ->
          "\nYou were started by session #{id} (your requester). Report progress and your " <>
            "final result to it with send_message(to: \"requester\", ...). Always send a " <>
            "final message before you finish."
      end

    """
    ## Legend messaging

    You are agent session #{session.id} in Legend, an orchestrator that runs multiple \
    agent sessions which can message each other. You have these MCP tools on the \
    `legend` server:

    - send_message(to, content): message another session; to is a session id, or "requester" for the session that started you
    - read_messages(): read your unread inbox. A line like "[legend] N unread message(s) ..." appearing in your input means you should call this
    - start_agent(harness, instructions, name?, cwd?): delegate — start another agent session; it is told to report back to you and you get a system message when it exits
    - handoff(to, summary): pass your work to another session (session id) or a fresh agent (harness id); the summary should carry full state and next steps
    - list_agents(): list all sessions and their status

    Put large content in the shared library (path in LEGEND_LIBRARY) and send paths, \
    not file bodies.#{spawner}
    """
  end
end
