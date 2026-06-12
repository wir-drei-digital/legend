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
  alias Legend.Core.Harness.Terminal
  alias Legend.Core.Signals

  @nudge_debounce_ms Application.compile_env(:legend, :nudge_debounce_ms, 2_000)
  @nudge_submit_delay_ms Application.compile_env(:legend, :nudge_submit_delay_ms, 150)

  ## Client API

  def start_session(%Agents.Session{} = session, mode \\ :fresh) do
    DynamicSupervisor.start_child(
      Legend.Core.Agents.SessionSupervisor,
      {__MODULE__, {session, mode}}
    )
  end

  def start_link({session, mode}) do
    GenServer.start_link(__MODULE__, {session, mode}, name: via(session.id))
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
  def init({session, mode}) do
    Process.flag(:trap_exit, true)

    with {:ok, harness} <- fetch_registered(Legend.Core.Harness.Registry, session.harness_id),
         {:ok, runtime} <- fetch_registered(Legend.Core.Runtime.Registry, session.runtime_id),
         spec = harness.build_command(build_opts(session, mode)),
         spec = %{spec | env: Map.merge(spec.env, platform_env(session))},
         {:ok, handle} <- runtime.start(spec, %{owner: self(), cwd: session.cwd}) do
      try do
        session = Agents.mark_session_running!(session)
        broadcast(session.id, {:session_status, :running})
        Notifications.sessions_changed()
        Phoenix.PubSub.subscribe(Legend.PubSub, Signals.Notifications.inbox_topic(session.id))

        # Catch-up: messages that arrived while this session had no live server
        # (downtime, or sent during :starting) are sitting unread — re-feed them
        # through the normal debounced-nudge path so the agent gets one knock.
        for message <- Signals.unread_messages!(session.id) do
          send(self(), {:new_message, Signals.Notifications.summary(message)})
        end

        {:ok,
         %{
           session: session,
           harness: harness,
           runtime: runtime,
           handle: handle,
           scrollback: Scrollback.new(),
           offset: 0,
           exited?: false,
           nudge_count: 0,
           nudge_froms: MapSet.new(),
           nudge_timer: nil
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

  defp build_opts(session, mode) do
    base = %{
      library: %{path: Legend.Core.Library.root(), primer: Legend.Core.Library.primer()},
      messaging: %{
        primer: Signals.messaging_primer(session),
        instructions: session.instructions
      },
      mode: mode,
      session_id: session.id
    }

    case session.mcp_token do
      nil -> base
      token -> Map.put(base, :mcp, %{url: mcp_url(), token: token})
    end
  end

  # The web endpoint knows the reachable base URL in every mode (dev :4100,
  # web/sidecar :4807, test :4002).
  defp mcp_url, do: LegendWeb.Endpoint.url() <> "/api/mcp"

  defp platform_env(session) do
    %{"LEGEND_LIBRARY" => Legend.Core.Library.root(), "LEGEND_SESSION_ID" => session.id}
    |> maybe_put("LEGEND_MCP_URL", session.mcp_token && mcp_url())
    |> maybe_put("LEGEND_SESSION_TOKEN", session.mcp_token)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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

  def handle_info({:new_message, _summary}, %{exited?: true} = state), do: {:noreply, state}

  def handle_info({:new_message, summary}, state) do
    timer = state.nudge_timer || Process.send_after(self(), :nudge_flush, @nudge_debounce_ms)

    {:noreply,
     %{
       state
       | nudge_count: state.nudge_count + 1,
         nudge_froms: MapSet.put(state.nudge_froms, summary.from_label),
         nudge_timer: timer
     }}
  end

  def handle_info(:nudge_flush, %{exited?: true} = state), do: {:noreply, reset_nudge(state)}
  def handle_info(:nudge_flush, %{nudge_count: 0} = state), do: {:noreply, reset_nudge(state)}

  def handle_info(:nudge_flush, state) do
    from = state.nudge_froms |> MapSet.to_list() |> Enum.sort() |> Enum.join(", ")
    line = Terminal.nudge_line(state.harness, state.nudge_count, from)
    state.runtime.write(state.handle, line)
    # The CR must arrive as a separate, later keypress: ink-based TUIs (Claude
    # Code) treat text+CR in one chunk as a paste — inserted, never submitted.
    Process.send_after(self(), :nudge_submit, @nudge_submit_delay_ms)
    {:noreply, reset_nudge(state)}
  end

  def handle_info(:nudge_submit, %{exited?: true} = state), do: {:noreply, state}

  def handle_info(:nudge_submit, state) do
    state.runtime.write(state.handle, "\r")
    {:noreply, state}
  end

  def handle_info({:runtime_exit, _code}, %{exited?: true} = state), do: {:noreply, state}

  def handle_info({:runtime_exit, code}, state) do
    session = Agents.finish_session!(state.session, %{exit_code: code})
    notify_spawner_of_exit(session, code)
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

  defp reset_nudge(state) do
    %{state | nudge_count: 0, nudge_froms: MapSet.new(), nudge_timer: nil}
  end

  defp notify_spawner_of_exit(%{spawned_by_session_id: nil}, _code), do: :ok

  defp notify_spawner_of_exit(session, code) do
    # Best effort: a failed system message must not break exit handling.
    Signals.send_message(%{
      from_session_id: session.id,
      to_session_id: session.spawned_by_session_id,
      kind: :system,
      payload:
        "Session #{session.name || session.harness_id} (#{session.id}) exited with code #{inspect(code)}."
    })

    :ok
  end

  defp broadcast(id, msg) do
    Phoenix.PubSub.broadcast(Legend.PubSub, "session:#{id}", msg)
  end
end
