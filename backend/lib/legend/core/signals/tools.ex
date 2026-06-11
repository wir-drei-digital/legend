defmodule Legend.Core.Signals.Tools do
  @moduledoc """
  The MCP tool surface for messaging. Pure dispatch from (caller session, tool
  name, string-keyed args) to {:ok, text} | {:error, text}; the MCP controller
  wraps results in JSON-RPC. The caller session comes from token auth — agents
  never assert their own identity.
  """

  alias Legend.Core.Agents
  alias Legend.Core.Harness
  alias Legend.Core.Signals

  def list do
    [
      %{
        name: "send_message",
        description:
          "Send a message to another Legend agent session. Use to: \"requester\" to reach the session that started you.",
        inputSchema: %{
          type: "object",
          properties: %{
            to: %{type: "string", description: "target session id, or \"requester\""},
            content: %{type: "string", description: "the message text"}
          },
          required: ["to", "content"]
        }
      },
      %{
        name: "read_messages",
        description:
          "Read and clear your unread inbox of messages from other sessions and the human.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "start_agent",
        description:
          "Start another agent session to delegate work to. It receives your instructions at launch, is told to report back to you, and you get a system message when it exits.",
        inputSchema: %{
          type: "object",
          properties: %{
            harness: %{
              type: "string",
              description: "harness id, e.g. \"claude_code\" or \"hermes\""
            },
            instructions: %{type: "string", description: "the task for the new agent"},
            name: %{type: "string", description: "optional display name"},
            cwd: %{type: "string", description: "optional working directory (defaults to yours)"}
          },
          required: ["harness", "instructions"]
        }
      },
      %{
        name: "handoff",
        description:
          "Hand your work off and step back. to is an existing session id, or a harness id to spawn a fresh agent with your summary as its launch context. The summary must carry full state and next steps.",
        inputSchema: %{
          type: "object",
          properties: %{
            to: %{type: "string", description: "session id or harness id"},
            summary: %{type: "string", description: "full state of the work and next steps"}
          },
          required: ["to", "summary"]
        }
      },
      %{
        name: "list_agents",
        description: "List all Legend sessions with their status.",
        inputSchema: %{type: "object", properties: %{}}
      }
    ]
  end

  def dispatch(session, "send_message", %{"to" => to, "content" => content})
      when is_binary(to) and is_binary(content) do
    with {:ok, target_id} <- resolve_target(session, to) do
      create_message(session.id, target_id, :message, content)
    end
  end

  def dispatch(session, "read_messages", _args) do
    case Signals.read_inbox!(session.id) do
      [] -> {:ok, "No unread messages."}
      messages -> {:ok, Enum.map_join(messages, "\n\n", &format_message/1)}
    end
  end

  def dispatch(
        session,
        "start_agent",
        %{"harness" => harness, "instructions" => instructions} = args
      )
      when is_binary(harness) and is_binary(instructions) do
    start_agent(session, harness, instructions, args["name"], args["cwd"])
  end

  def dispatch(session, "handoff", %{"to" => to, "summary" => summary})
      when is_binary(to) and is_binary(summary) do
    case Agents.get_session(to) do
      {:ok, target} ->
        create_message(session.id, target.id, :handoff, summary)

      {:error, _} ->
        case Harness.Registry.fetch(to) do
          {:ok, _module} -> handoff_spawn(session, to, summary)
          :error -> {:error, "unknown session or harness id: #{to}"}
        end
    end
  end

  def dispatch(_session, "list_agents", _args) do
    lines =
      Enum.map_join(Agents.list_sessions!(), "\n", fn s ->
        "#{s.id} | #{s.name || "-"} | #{s.harness_id} | #{s.status}"
      end)

    {:ok, "id | name | harness | status\n" <> lines}
  end

  def dispatch(_session, name, _args) do
    {:error, "unknown tool or missing required arguments: #{name}"}
  end

  defp resolve_target(session, "requester") do
    case session.spawned_by_session_id do
      nil -> {:error, "this session has no requester — pass an explicit session id"}
      id -> {:ok, id}
    end
  end

  defp resolve_target(_session, to) do
    case Agents.get_session(to) do
      {:ok, target} -> {:ok, target.id}
      {:error, _} -> {:error, "unknown session: #{to}"}
    end
  end

  defp create_message(from_id, to_id, kind, payload) do
    case Signals.send_message(%{
           from_session_id: from_id,
           to_session_id: to_id,
           kind: kind,
           payload: payload
         }) do
      {:ok, message} -> {:ok, "Delivered (message #{message.id})."}
      {:error, error} -> {:error, "delivery failed: #{Exception.message(error)}"}
    end
  end

  defp start_agent(session, harness, instructions, name, cwd) do
    max = Application.get_env(:legend, :max_running_sessions, 10)

    cond do
      Harness.Registry.fetch(harness) == :error ->
        {:error, "unknown harness: #{harness}. Known: #{known_harnesses()}"}

      running_count() >= max ->
        {:error, "session cap reached (#{max} running) — stop a session first"}

      true ->
        case Agents.start_session(%{
               harness_id: harness,
               name: name,
               cwd: cwd || session.cwd,
               spawned_by_session_id: session.id,
               instructions: instructions
             }) do
          {:ok, %{status: :failed} = failed} ->
            {:error, "agent failed to start: #{failed.error}"}

          {:ok, new_session} ->
            audit(
              session.id,
              new_session.id,
              :system,
              "started with instructions:\n#{instructions}"
            )

            {:ok,
             "Started session #{new_session.id} (#{harness}). It was told to report back " <>
               "to you; you will also get a system message when it exits."}

          {:error, error} ->
            {:error, "could not start agent: #{Exception.message(error)}"}
        end
    end
  end

  defp handoff_spawn(session, harness, summary) do
    instructions =
      "You are taking over work handed off by another agent. Handoff summary:\n\n" <> summary

    with {:ok, text} <- start_agent(session, harness, instructions, nil, nil) do
      {:ok, "Handed off. " <> text}
    end
  end

  # Timeline audit record for content delivered out of band (at launch):
  # created already-read so it never nudges.
  defp audit(from_id, to_id, kind, payload) do
    Signals.send_message(%{
      from_session_id: from_id,
      to_session_id: to_id,
      kind: kind,
      payload: payload,
      read_at: DateTime.utc_now()
    })

    :ok
  end

  defp running_count do
    Enum.count(Agents.list_sessions!(), &(&1.status in [:starting, :running]))
  end

  defp known_harnesses do
    Enum.map_join(Harness.Registry.list(), ", ", & &1.id)
  end

  defp format_message(message) do
    summary = Signals.Notifications.summary(message)

    "[#{message.inserted_at} | #{message.kind} | from #{summary.from_label} " <>
      "(#{message.from_session_id || "human"})] #{message.payload}"
  end
end
