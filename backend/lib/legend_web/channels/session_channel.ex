defmodule LegendWeb.SessionChannel do
  @moduledoc """
  Live IO for one session. Join replies with the current status and a base64
  scrollback replay; `output` events carry base64 chunks. The `offset` filter
  drops PubSub chunks that are already contained in the join-time snapshot.
  """

  use LegendWeb, :channel

  alias Legend.Core.Agents
  alias Legend.Core.Agents.SessionServer

  @impl true
  def join("session:" <> id, _payload, socket) do
    case Agents.get_session(id) do
      {:ok, session} ->
        Phoenix.PubSub.subscribe(Legend.PubSub, "session:#{id}")
        {reply, offset} = attach_reply(session)
        {:ok, reply, assign(socket, session_id: id, offset: offset)}

      {:error, _} ->
        {:error, %{reason: "not found"}}
    end
  end

  defp attach_reply(session) do
    case SessionServer.attach(session.id) do
      {:ok, %{status: status, buffer: buffer, offset: offset}} ->
        {%{
           status: to_string(status),
           buffer: Base.encode64(buffer),
           exit_code: session.exit_code,
           error: session.error
         }, offset}

      {:error, :not_running} ->
        {%{
           status: to_string(session.status),
           buffer: "",
           exit_code: session.exit_code,
           error: session.error
         }, 0}
    end
  end

  @impl true
  def handle_in("input", %{"data" => data}, socket) when is_binary(data) do
    SessionServer.write(socket.assigns.session_id, data)
    {:noreply, socket}
  end

  def handle_in("resize", %{"cols" => cols, "rows" => rows}, socket)
      when is_integer(cols) and is_integer(rows) and cols > 0 and rows > 0 do
    SessionServer.resize(socket.assigns.session_id, cols, rows)
    {:noreply, socket}
  end

  def handle_in("stop", _payload, socket) do
    SessionServer.stop(socket.assigns.session_id)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:session_output, chunk_offset, data}, socket) do
    if chunk_offset >= socket.assigns.offset do
      push(socket, "output", %{data: Base.encode64(data)})
      {:noreply, assign(socket, :offset, chunk_offset + byte_size(data))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:session_exit, exit_code}, socket) do
    push(socket, "exit", %{exit_code: exit_code})
    {:noreply, socket}
  end

  def handle_info({:session_status, status}, socket) do
    push(socket, "status", %{status: to_string(status)})
    {:noreply, socket}
  end
end
