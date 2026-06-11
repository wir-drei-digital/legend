defmodule Legend.Core.Agents.SessionServer do
  @moduledoc """
  One process per live session. Resolves harness -> command spec -> runtime,
  owns the scrollback buffer, broadcasts output on PubSub topic
  `session:<id>` as `{:session_output, chunk_offset, data}`, and keeps the
  session record in sync. Stays alive after runtime exit (status :exited) so
  scrollback remains viewable until the session is deleted.
  """

  use GenServer, restart: :temporary

  alias Legend.Core.Agents
  alias Legend.Core.Agents.Notifications
  alias Legend.Core.Agents.Scrollback

  ## Client API

  def start_session(%Agents.Session{} = session) do
    DynamicSupervisor.start_child(Legend.Core.Agents.SessionSupervisor, {__MODULE__, session})
  end

  def start_link(session) do
    GenServer.start_link(__MODULE__, session, name: via(session.id))
  end

  @doc """
  Returns {:ok, %{status, buffer, offset}} or {:error, :not_running}.

  The returned `offset` is both the byte length of the snapshot and the offset
  at which live `{:session_output, chunk_offset, data}` chunks resume — channel
  consumers drop chunks with `chunk_offset < offset`.
  """
  def attach(id), do: call(id, :attach)

  def write(id, data), do: cast(id, {:write, data})
  def resize(id, cols, rows), do: cast(id, {:resize, cols, rows})
  def stop(id), do: cast(id, :stop)

  @doc "Terminates the server (and its runtime) if alive. Used by destroy."
  def ensure_stopped(id) do
    case Registry.lookup(Legend.Core.Agents.SessionRegistry, id) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
        :ok

      [] ->
        :ok
    end
  end

  def whereis(id) do
    case Registry.lookup(Legend.Core.Agents.SessionRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp via(id), do: {:via, Registry, {Legend.Core.Agents.SessionRegistry, id}}

  defp call(id, msg) do
    case whereis(id) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, msg)
    end
  end

  defp cast(id, msg) do
    case whereis(id) do
      nil -> {:error, :not_running}
      pid -> GenServer.cast(pid, msg)
    end
  end

  ## Server

  @impl true
  def init(session) do
    Process.flag(:trap_exit, true)

    with {:ok, harness} <- fetch_registered(Legend.Core.Harness.Registry, session.harness_id),
         {:ok, runtime} <- fetch_registered(Legend.Core.Runtime.Registry, session.runtime_id),
         spec = harness.build_command(%{}),
         {:ok, handle} <- runtime.start(spec, %{owner: self(), cwd: session.cwd}) do
      try do
        session = Agents.mark_session_running!(session)
        broadcast(session.id, {:session_status, :running})
        Notifications.sessions_changed()

        {:ok,
         %{
           session: session,
           runtime: runtime,
           handle: handle,
           scrollback: Scrollback.new(),
           offset: 0,
           exited?: false
         }}
      rescue
        e ->
          # The record write failed (e.g. deleted concurrently) — don't leak
          # the just-started OS process, and best-effort mark the record.
          runtime.stop(handle)

          try do
            Agents.fail_session!(session, %{error: Exception.message(e)})
            Notifications.sessions_changed()
          rescue
            _ -> :ok
          end

          :ignore
      end
    else
      {:error, reason} ->
        Agents.fail_session!(session, %{error: reason})
        Notifications.sessions_changed()
        :ignore
    end
  end

  defp fetch_registered(registry, id) do
    case registry.fetch(id) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, "not registered: #{id}"}
    end
  end

  @impl true
  def handle_call(:attach, _from, state) do
    reply = %{
      status: state.session.status,
      buffer: Scrollback.to_binary(state.scrollback),
      offset: state.offset
    }

    {:reply, {:ok, reply}, state}
  end

  @impl true
  def handle_cast({:write, _data}, %{exited?: true} = state), do: {:noreply, state}

  def handle_cast({:write, data}, state) do
    state.runtime.write(state.handle, data)
    {:noreply, state}
  end

  def handle_cast({:resize, _c, _r}, %{exited?: true} = state), do: {:noreply, state}

  def handle_cast({:resize, cols, rows}, state) do
    state.runtime.resize(state.handle, cols, rows)
    {:noreply, state}
  end

  def handle_cast(:stop, %{exited?: true} = state), do: {:noreply, state}

  def handle_cast(:stop, state) do
    state.runtime.stop(state.handle)
    {:noreply, state}
  end

  @impl true
  def handle_info({:runtime_output, data}, state) do
    broadcast(state.session.id, {:session_output, state.offset, data})

    {:noreply,
     %{
       state
       | scrollback: Scrollback.append(state.scrollback, data),
         offset: state.offset + byte_size(data)
     }}
  end

  def handle_info({:runtime_exit, _code}, %{exited?: true} = state), do: {:noreply, state}

  def handle_info({:runtime_exit, code}, state) do
    session = Agents.finish_session!(state.session, %{exit_code: code})
    broadcast(session.id, {:session_exit, code})
    Notifications.sessions_changed()
    {:noreply, %{state | session: session, exited?: true}}
  end

  # Runtime helper processes exit normally after forwarding runtime_exit.
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  # A crashed runtime process counts as an exit without a code.
  def handle_info({:EXIT, _pid, _reason}, %{exited?: false} = state) do
    handle_info({:runtime_exit, nil}, state)
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{exited?: false} = state) do
    state.runtime.stop(state.handle)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp broadcast(id, msg) do
    Phoenix.PubSub.broadcast(Legend.PubSub, "session:#{id}", msg)
  end
end
