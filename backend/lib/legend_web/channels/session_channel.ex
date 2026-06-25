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
        maybe_audit_attach(socket.assigns[:device_id], id)
        Phoenix.PubSub.subscribe(Legend.PubSub, "session:#{id}")
        {reply, offset} = attach_reply(session)
        {:ok, reply, assign(socket, session_id: id, offset: offset)}

      {:error, _} ->
        {:error, %{reason: "not found"}}
    end
  end

  defp maybe_audit_attach(nil, _session_id), do: :ok

  defp maybe_audit_attach(device_id, session_id),
    do:
      Legend.Core.Devices.audit!(%{
        device_id: device_id,
        session_id: session_id,
        action: "attach"
      })

  # Record a remote device's control action (stop/prompt/permission). Loopback
  # sockets (device_id nil) are not audited; keystrokes/view changes are not
  # control actions and so don't reach this helper.
  defp audit_control(%{assigns: %{device_id: device_id, session_id: session_id}}, action)
       when is_binary(device_id) do
    Legend.Core.Devices.audit!(%{device_id: device_id, session_id: session_id, action: action})
  end

  defp audit_control(_socket, _action), do: :ok

  defp attach_reply(session) do
    case SessionServer.attach(session.id) do
      {:ok, %{transport: :acp, items: items, cursor: cursor, status: status, busy: busy}} ->
        {%{
           status: to_string(status),
           transport: "acp",
           items: items,
           cursor: cursor,
           busy: busy,
           exit_code: session.exit_code,
           error: session.error
         }, cursor}

      {:ok, %{status: status, buffer: buffer, offset: offset}} ->
        {%{
           status: to_string(status),
           transport: "terminal",
           buffer: Base.encode64(buffer),
           exit_code: session.exit_code,
           error: session.error
         }, offset}

      {:error, :not_running} ->
        {%{
           status: to_string(session.status),
           transport: to_string(session.transport),
           buffer: "",
           items: [],
           cursor: 0,
           busy: false,
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
    audit_control(socket, "stop")
    SessionServer.stop(socket.assigns.session_id)
    {:noreply, socket}
  end

  # --- ACP inbound (ignored on terminal sessions by the SessionServer guards) ---

  def handle_in("prompt", %{"content" => content}, socket)
      when is_binary(content) or is_list(content) do
    audit_control(socket, "prompt")
    SessionServer.acp_prompt(socket.assigns.session_id, content)
    {:noreply, socket}
  end

  def handle_in("cancel", _payload, socket) do
    SessionServer.acp_cancel(socket.assigns.session_id)
    {:noreply, socket}
  end

  def handle_in("set_mode", %{"mode" => mode}, socket) when is_binary(mode) do
    SessionServer.acp_set_mode(socket.assigns.session_id, mode)
    {:noreply, socket}
  end

  def handle_in("set_model", %{"model" => model}, socket) when is_binary(model) do
    SessionServer.acp_set_model(socket.assigns.session_id, model)
    {:noreply, socket}
  end

  def handle_in("permission", %{"request_id" => req, "option_id" => opt}, socket)
      when is_binary(req) and is_binary(opt) do
    audit_control(socket, "permission")
    SessionServer.acp_permission(socket.assigns.session_id, req, opt)
    {:noreply, socket}
  end

  # Catch-all: an unknown event, or a known event whose payload matches no clause
  # above, must not crash the per-viewer channel with a FunctionClauseError.
  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:session_output, chunk_offset, data}, socket) do
    if chunk_offset >= socket.assigns.offset do
      push(socket, "output", %{data: Base.encode64(data)})
      {:noreply, assign(socket, :offset, chunk_offset + byte_size(data))}
    else
      {:noreply, socket}
    end
  end

  # ACP outbound: reuse the `offset` assign as the ACP `seq` cursor so events
  # already contained in the join-time snapshot are dropped. The cursor is the
  # snapshot's LAST seq (inclusive), so the gate is half-open (`seq > offset`)
  # to avoid re-pushing the boundary item already in the snapshot.
  def handle_info({:session_event, seq, item}, socket) do
    if seq > socket.assigns.offset do
      push(socket, "event", %{seq: seq, item: item})
      {:noreply, assign(socket, :offset, seq)}
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
