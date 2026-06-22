defmodule Legend.Core.Agents.SessionServer do
  @moduledoc """
  One process per live session. Resolves harness -> command spec -> runtime and
  keeps the session record in sync. Stays alive after runtime exit (status
  :exited) so the snapshot remains viewable until the session is deleted.

  Two transports, branched on `session.transport`:

    * `:terminal` — owns a byte scrollback; broadcasts `{:session_output,
      chunk_offset, data}` on `session:<id>`; accepts `write`/`resize` casts.
    * `:acp` — runs the Agent Client Protocol handshake over an `io: :pipes`
      adapter via `Acp.Connection`; reduces runtime output into render items
      appended to an `AcpTimeline`; broadcasts `{:session_event, seq, item}`;
      accepts `acp_prompt`/`acp_cancel`/`acp_set_mode`/`acp_permission` casts.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Legend.Core.Agents
  alias Legend.Core.Agents.Notifications
  alias Legend.Core.Agents.Scrollback
  alias Legend.Core.Harness.Terminal
  alias Legend.Core.Signals

  @nudge_debounce_ms Application.compile_env(:legend, :nudge_debounce_ms, 2_000)
  @nudge_submit_delay_ms Application.compile_env(:legend, :nudge_submit_delay_ms, 150)

  # ACP-only handshake watchdog: a spawned-but-silent adapter (hung / wrong
  # binary / protocol stall) would otherwise stay :running forever with an empty
  # timeline. Armed when the launch writes its init frames, disarmed by the
  # {:session_ready} effect; if it fires first the session is marked :failed.
  @acp_handshake_timeout_ms Application.compile_env(:legend, :acp_handshake_timeout_ms, 30_000)

  # Cap on the server-side mid-turn prompt queue (drained one-per-turn). If
  # prompts arrive faster than turns complete the queue would grow without
  # bound; at the cap the NEWEST (incoming) prompt is dropped — already-accepted
  # prompts keep their order — and the drop is logged for observability.
  @max_acp_prompt_queue 50

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
  Returns `{:error, :not_running}`, or `{:ok, snapshot}` whose shape is
  transport-dependent:

    * terminal — `%{status, transport: :terminal, buffer, offset}`. The `offset`
      is both the byte length of the snapshot and the offset at which live
      `{:session_output, chunk_offset, data}` chunks resume — channel consumers
      drop chunks with `chunk_offset < offset`.
    * acp — `%{status, transport: :acp, items, cursor}`. `items` is the reduced
      timeline replay and `cursor` is the seq at which live
      `{:session_event, seq, item}` broadcasts resume — consumers drop events
      with `seq <= cursor`.
  """
  def attach(id), do: call(id, :attach)

  def write(id, data), do: cast(id, {:write, data})
  def resize(id, cols, rows), do: cast(id, {:resize, cols, rows})
  def stop(id), do: cast(id, :stop)

  # ACP client operations (no-ops on a terminal session).
  def acp_prompt(id, content), do: cast(id, {:acp_prompt, content})
  def acp_cancel(id), do: cast(id, :acp_cancel)
  def acp_set_mode(id, mode), do: cast(id, {:acp_set_mode, mode})

  def acp_permission(id, request_id, option_id),
    do: cast(id, {:acp_permission, request_id, option_id})

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
         caps = Legend.Core.Runtime.capabilities(runtime),
         :ok <- maybe_provision(session, harness, runtime, caps),
         {:ok, tunnel, base_url} <- maybe_open_tunnel(session, caps) do
      # The tunnel is open from here on, so every failure path below MUST close
      # it (a leaked SpriteProxy.Server would otherwise reconnect forever).
      launch(session, mode, harness, runtime, caps, tunnel, base_url)
    else
      {:error, reason} ->
        Agents.fail_session!(session, %{error: reason})
        Notifications.sessions_changed()
        :ignore
    end
  end

  defp launch(session, mode, harness, runtime, caps, tunnel, base_url) do
    spec = build_spec(session, mode, harness, caps, base_url)

    case start_or_attach(runtime, spec, session, mode) do
      {:ok, handle, ref} ->
        try do
          session = Agents.mark_session_running!(session, %{runtime_ref: ref})
          broadcast(session.id, {:session_status, :running})
          Notifications.sessions_changed()
          Phoenix.PubSub.subscribe(Legend.PubSub, Signals.Notifications.inbox_topic(session.id))

          # ACP: drive the launch handshake (initialize → session/new|load) by
          # writing the connection's opening frames to the freshly started pipe.
          transport_state = start_transport(session, runtime, handle, caps, base_url)

          # ACP only: arm the handshake watchdog now that the init frames are out.
          # A silent/hung adapter that never completes the handshake would stay
          # :running forever; the timer fires :acp_handshake_timeout to fail it.
          # {:session_ready} cancels it (apply_effect/2).
          transport_state = maybe_arm_handshake_watchdog(transport_state)

          # Terminal: pin the shared conversation handle to the session id on a
          # fresh launch so a later transport switch resumes the SAME conversation
          # (--session-id session.id was already used at this launch). ACP captures
          # its own id from session/new via apply_effect/2, so skip it here.
          session = maybe_pin_terminal_conversation_id(session, mode)

          # Catch-up: messages that arrived while this session had no live server
          # (downtime, or sent during :starting) are sitting unread — re-feed them
          # through the normal debounced-nudge path so the agent gets one knock.
          for message <- Signals.unread_messages!(session.id) do
            send(self(), {:new_message, Signals.Notifications.summary(message)})
          end

          {:ok,
           Map.merge(transport_state, %{
             session: session,
             harness: harness,
             runtime: runtime,
             handle: handle,
             tunnel: tunnel,
             exited?: false,
             nudge_count: 0,
             nudge_froms: MapSet.new(),
             nudge_timer: nil
           })}
        rescue
          e ->
            # The record write failed (e.g. deleted concurrently) — don't leak
            # the just-started OS process or the tunnel; best-effort mark the record.
            runtime.stop(handle)
            maybe_close_tunnel(tunnel)

            try do
              Agents.fail_session!(session, %{error: Exception.message(e)})
              Notifications.sessions_changed()
            rescue
              _ -> :ok
            end

            :ignore
        end

      {:error, reason} ->
        # Runtime failed to start — close the tunnel we already opened.
        maybe_close_tunnel(tunnel)
        Agents.fail_session!(session, %{error: reason})
        Notifications.sessions_changed()
        :ignore
    end
  end

  # Transport-aware command build. Terminal merges platform_env onto the
  # harness's CLI spec; ACP spawns the adapter subprocess (io: :pipes) with the
  # same platform_env — the protocol wiring (cwd/mcpServers/instructions) is
  # driven generically by Acp.Connection, not via CLI flags.
  defp build_spec(session, mode, harness, caps, base_url) do
    case session.transport do
      :acp ->
        harness.acp_command(%{env: platform_env(session, caps, base_url)})

      _terminal ->
        spec = harness.build_command(build_opts(session, mode, caps, base_url))
        %{spec | env: Map.merge(spec.env, platform_env(session, caps, base_url))}
    end
  end

  # Returns the transport-specific slice of process state. For ACP this also
  # initializes the Acp.Connection and writes its opening frames to the runtime,
  # and may persist a captured conversation id (none yet at launch). Terminal
  # keeps the byte scrollback; ACP keeps the reduced-item timeline.
  defp start_transport(%{transport: :acp} = session, runtime, handle, caps, base_url) do
    mode = if session.conversation_id, do: :load, else: :new

    {acp, frames} =
      Legend.Core.Acp.Connection.new(%{
        cwd: session.cwd,
        mcp_servers: acp_mcp_servers(session, caps, base_url),
        mode: mode,
        conversation_id: session.conversation_id,
        instructions: if(mode == :new, do: session.instructions)
      })

    Enum.each(frames, &runtime.write(handle, &1))

    %{
      transport: :acp,
      acp: acp,
      timeline: Legend.Core.Agents.AcpTimeline.new(),
      # Server-side one-turn-at-a-time queue: prompts cast while a turn is in
      # flight are held here (FIFO) and flushed one per turn-complete. A
      # coalesced nudge line (or nil) is deferred to wake the agent post-turn.
      acp_prompt_queue: [],
      pending_nudge: nil,
      # Handshake watchdog timer ref; armed in launch/7, cancelled by
      # {:session_ready}/{:handshake_failed}. nil = disarmed (or terminal).
      acp_handshake_timer: nil,
      scrollback: nil,
      offset: nil
    }
  end

  defp start_transport(_session, _runtime, _handle, _caps, _base_url) do
    %{
      transport: :terminal,
      acp: nil,
      timeline: nil,
      acp_prompt_queue: [],
      pending_nudge: nil,
      acp_handshake_timer: nil,
      scrollback: Scrollback.new(),
      offset: 0
    }
  end

  # ACP mcpServers entry — same loopback http target the terminal path turns into
  # CLI --mcp-config flags (Phase 1 local: the tunnel base url or the endpoint).
  defp acp_mcp_servers(%{mcp_token: nil}, _caps, _base_url), do: []

  defp acp_mcp_servers(session, %{library: :api}, base_url) when is_binary(base_url) do
    [
      %{
        "name" => "legend",
        "type" => "http",
        "url" => base_url <> "/api/mcp",
        "headers" => acp_auth_headers(session.mcp_token)
      }
    ]
  end

  defp acp_mcp_servers(session, _caps, _base_url) do
    [
      %{
        "name" => "legend",
        "type" => "http",
        "url" => mcp_url(),
        "headers" => acp_auth_headers(session.mcp_token)
      }
    ]
  end

  # ACP's HTTP McpServer schema (zMcpServerHttp) requires `headers` to be an
  # ARRAY of {name, value} objects — NOT the {name => value} map the Claude Code
  # CLI's --mcp-config uses. A map fails the adapter's zod validation with
  # JSON-RPC -32602 "Invalid params", which fails the handshake (session :failed).
  defp acp_auth_headers(token), do: [%{"name" => "Authorization", "value" => "Bearer #{token}"}]

  defp fetch_registered(registry, id) do
    case registry.fetch(id) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, "not registered: #{id}"}
    end
  end

  # Provisioning runs BEFORE the PTY exists, so exec targets the runtime via a
  # lightweight handle carrying the session id. The Sprites runtime ensures the
  # sprite (idempotent, keyed by session id) so exec works pre-start; the Test
  # runtime ignores the handle. Only reached when the runtime declares provisions?.
  defp maybe_provision(session, harness, runtime, %{provisions?: true}) do
    case Legend.Core.Harness.provision_for(harness, session.transport) do
      nil ->
        {:error, "harness #{session.harness_id} has no installer for this runtime"}

      %{detect: detect, install: install} ->
        handle = %{session_id: session.id}

        case runtime.exec(handle, detect) do
          {:ok, %{status: 0}} ->
            :ok

          {:ok, _missing} ->
            Agents.mark_session_provisioning!(session)
            broadcast(session.id, {:session_status, :provisioning})
            Notifications.sessions_changed()

            case runtime.exec(handle, install) do
              {:ok, %{status: 0}} -> :ok
              {:ok, %{stdout: out, status: s}} -> {:error, "install failed (#{s}): #{out}"}
              {:error, reason} -> {:error, "install failed: #{reason}"}
            end

          {:error, reason} ->
            {:error, "provision detect failed: #{reason}"}
        end
    end
  end

  defp maybe_provision(_session, _harness, _runtime, _caps), do: :ok

  defp maybe_open_tunnel(_session, %{tunnel: nil}), do: {:ok, nil, nil}

  defp maybe_open_tunnel(session, %{tunnel: tid}) do
    case Legend.Core.Tunnel.Registry.fetch(tid) do
      {:ok, tunnel} ->
        case tunnel.open(%{session_id: session.id}) do
          {:ok, %{base_url: url, handle: h}} -> {:ok, {tunnel, h}, url}
          {:error, reason} -> {:error, "tunnel open failed: #{reason}"}
        end

      :error ->
        {:error, "tunnel not registered: #{tid}"}
    end
  end

  defp maybe_close_tunnel(nil), do: :ok
  defp maybe_close_tunnel({tunnel, handle}), do: tunnel.close(handle)

  defp start_or_attach(runtime, spec, session, :resume) do
    # Attach-to-live is a terminal-only PTY reconnect. ACP resume must relaunch the
    # adapter and replay via session/load — never reattach to the already-initialized
    # adapter exec.
    if session.transport == :terminal and function_exported?(runtime, :attach, 2) and
         not is_nil(session.runtime_ref) do
      case runtime.attach(session.runtime_ref, start_opts(session)) do
        {:ok, handle} -> {:ok, handle, session.runtime_ref}
        {:error, _} -> do_start(runtime, spec, session)
      end
    else
      do_start(runtime, spec, session)
    end
  end

  # A transport switch always starts a fresh process for the NEW transport (the
  # persisted runtime_ref belongs to the old transport's exec). The conversation is
  # resumed at the protocol layer (terminal --resume / ACP session/load).
  defp start_or_attach(runtime, spec, session, :switch), do: do_start(runtime, spec, session)

  defp start_or_attach(runtime, spec, session, _fresh), do: do_start(runtime, spec, session)

  defp do_start(runtime, spec, session) do
    case runtime.start(spec, start_opts(session)) do
      {:ok, handle} -> {:ok, handle, runtime_ref_from(handle)}
      {:error, _} = err -> err
    end
  end

  # start/attach opts. session_id lets a cloud runtime (sprites) key its sandbox;
  # LocalPty/Test ignore it.
  defp start_opts(session), do: %{owner: self(), cwd: session.cwd, session_id: session.id}

  # The handle a runtime returns may carry its reattach ref (sprites: %{sprite, exec_id});
  # LocalPty/Test return handles without one -> nil ref persisted.
  defp runtime_ref_from(%{sprite: s, exec_id: e}), do: %{"sprite" => s, "exec_id" => e}
  defp runtime_ref_from(_), do: nil

  # A switch resumes the conversation under the new transport (terminal --resume /
  # ACP session/load) but with a fresh process — so the harness sees :resume.
  defp conversation_mode(:switch), do: :resume
  defp conversation_mode(mode), do: mode

  # :api runtimes reach the library + signal bus over the tunnel (base_url loopback).
  defp build_opts(session, mode, %{library: :api}, base_url) do
    %{
      mode: conversation_mode(mode),
      # The shared cross-transport handle: terminal passes it as
      # --session-id/--resume. Nil at first launch → resolves to session.id
      # (unchanged terminal behavior).
      session_id: session.conversation_id || session.id,
      library: %{primer: Legend.Core.Library.primer(:api)},
      messaging: %{primer: Signals.messaging_primer(session), instructions: session.instructions}
    }
    |> put_mcp(session, base_url)
  end

  defp build_opts(session, mode, %{library: :path}, _base_url) do
    base = %{
      library: %{path: Legend.Core.Library.root(), primer: Legend.Core.Library.primer(:path)},
      messaging: %{
        primer: Signals.messaging_primer(session),
        instructions: session.instructions
      },
      mode: conversation_mode(mode),
      # The shared cross-transport handle: terminal passes it as
      # --session-id/--resume. Nil at first launch → resolves to session.id
      # (unchanged terminal behavior).
      session_id: session.conversation_id || session.id
    }

    case session.mcp_token do
      nil -> base
      token -> Map.put(base, :mcp, %{url: mcp_url(), token: token})
    end
  end

  defp put_mcp(opts, %{mcp_token: nil}, _base_url), do: opts
  defp put_mcp(opts, _session, nil), do: opts

  defp put_mcp(opts, session, base_url),
    do: Map.put(opts, :mcp, %{url: base_url <> "/api/mcp", token: session.mcp_token})

  # The web endpoint knows the reachable base URL in every mode (dev :4100,
  # web/sidecar :4807, test :4002).
  defp mcp_url, do: LegendWeb.Endpoint.url() <> "/api/mcp"

  defp platform_env(session, %{library: :api}, base_url) do
    %{"LEGEND_SESSION_ID" => session.id}
    |> maybe_put("LEGEND_MCP_URL", session.mcp_token && base_url && base_url <> "/api/mcp")
    |> maybe_put("LEGEND_SESSION_TOKEN", session.mcp_token)
  end

  defp platform_env(session, %{library: :path}, _base_url) do
    %{"LEGEND_LIBRARY" => Legend.Core.Library.root(), "LEGEND_SESSION_ID" => session.id}
    |> maybe_put("LEGEND_MCP_URL", session.mcp_token && mcp_url())
    |> maybe_put("LEGEND_SESSION_TOKEN", session.mcp_token)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @impl true
  def handle_call(:attach, _from, %{transport: :acp} = state) do
    {items, cursor} = Legend.Core.Agents.Transcript.snapshot(state.timeline)

    reply = %{
      status: state.session.status,
      transport: :acp,
      items: items,
      cursor: cursor,
      busy: Legend.Core.Acp.Connection.turn_in_flight?(state.acp)
    }

    {:reply, {:ok, reply}, state}
  end

  def handle_call(:attach, _from, state) do
    reply = %{
      status: state.session.status,
      transport: :terminal,
      buffer: Scrollback.to_binary(state.scrollback),
      offset: state.offset
    }

    {:reply, {:ok, reply}, state}
  end

  @impl true
  def handle_cast({:write, _data}, %{exited?: true} = state), do: {:noreply, state}

  # Raw byte writes are a terminal concept — never inject into an ACP pipe.
  def handle_cast({:write, data}, %{transport: :terminal} = state) do
    state.runtime.write(state.handle, data)
    {:noreply, state}
  end

  def handle_cast({:write, _data}, state), do: {:noreply, state}

  def handle_cast({:resize, _c, _r}, %{exited?: true} = state), do: {:noreply, state}

  def handle_cast({:resize, cols, rows}, %{transport: :terminal} = state) do
    state.runtime.resize(state.handle, cols, rows)
    {:noreply, state}
  end

  def handle_cast({:resize, _c, _r}, state), do: {:noreply, state}

  def handle_cast(:stop, %{exited?: true} = state), do: {:noreply, state}

  def handle_cast(:stop, state) do
    state.runtime.stop(state.handle)
    {:noreply, state}
  end

  # --- ACP inbound casts (no-ops after exit; ignored on a terminal session) ---

  def handle_cast({:acp_prompt, _content}, %{exited?: true} = state), do: {:noreply, state}

  def handle_cast({:acp_prompt, content}, %{transport: :acp} = state) do
    {:noreply, send_or_queue_prompt(state, content)}
  end

  def handle_cast(:acp_cancel, %{exited?: true} = state), do: {:noreply, state}

  def handle_cast(:acp_cancel, %{transport: :acp} = state) do
    {acp, frames} = Legend.Core.Acp.Connection.cancel(state.acp)
    Enum.each(frames, &state.runtime.write(state.handle, &1))
    {:noreply, %{state | acp: acp}}
  end

  def handle_cast({:acp_set_mode, _mode}, %{exited?: true} = state), do: {:noreply, state}

  def handle_cast({:acp_set_mode, mode}, %{transport: :acp} = state) do
    {acp, frames} = Legend.Core.Acp.Connection.set_mode(state.acp, mode)
    Enum.each(frames, &state.runtime.write(state.handle, &1))
    {:noreply, %{state | acp: acp}}
  end

  def handle_cast({:acp_permission, _req, _opt}, %{exited?: true} = state), do: {:noreply, state}

  def handle_cast({:acp_permission, req, opt}, %{transport: :acp} = state) do
    case Legend.Core.Acp.Connection.answer_permission(state.acp, req, opt) do
      # No reply frames means the request id is unknown/already-answered — do not
      # write to the runtime or append a spurious resolved item.
      {_acp, []} ->
        {:noreply, state}

      {acp, frames} ->
        Enum.each(frames, &state.runtime.write(state.handle, &1))

        # Mark the permission item resolved on the timeline so reattach/late readers
        # see the decision rather than a pending request.
        state =
          append_acp_item(%{state | acp: acp}, %{
            "id" => req,
            "type" => "permission",
            "resolved" => true,
            "selected" => opt
          })

        {:noreply, state}
    end
  end

  # An ACP cast that reached a terminal session (or vice versa) is a no-op.
  def handle_cast({:acp_prompt, _content}, state), do: {:noreply, state}
  def handle_cast(:acp_cancel, state), do: {:noreply, state}
  def handle_cast({:acp_set_mode, _mode}, state), do: {:noreply, state}
  def handle_cast({:acp_permission, _req, _opt}, state), do: {:noreply, state}

  @impl true
  def handle_info({:runtime_output, _data}, %{exited?: true} = state), do: {:noreply, state}

  def handle_info({:runtime_output, data}, %{transport: :acp} = state) do
    {acp, items, replies, effects} = Legend.Core.Acp.Connection.handle_bytes(state.acp, data)
    Enum.each(replies, &state.runtime.write(state.handle, &1))
    # I5: items FIRST, then effects. When a single pipe read carries both the
    # final agent_message_chunk and the session/prompt stopReason response, the
    # message item must land with a LOWER seq than the {:turn} item the response
    # emits. Reducing effects first would invert that ordering. Non-item effects
    # (:conversation_id, :load_capable) are order-insensitive.
    state = Enum.reduce(items, %{state | acp: acp}, &append_acp_item(&2, &1))
    state = Enum.reduce(effects, state, &apply_effect/2)
    {:noreply, state}
  end

  def handle_info({:runtime_output, data}, state) do
    broadcast(state.session.id, {:session_output, state.offset, data})

    {:noreply,
     %{
       state
       | scrollback: Scrollback.append(state.scrollback, data),
         offset: state.offset + byte_size(data)
     }}
  end

  # ACP (io: :pipes) delivers stderr as a SEPARATE erlexec stream (LocalPty tags
  # it {:runtime_stderr} so it never corrupts the stdout JSON-RPC frames). Log it
  # for observability — never feed it to Acp.Connection.handle_bytes/2. Terminal
  # (io: :pty) merges stderr into stdout at the kernel, so this never fires there.
  def handle_info({:runtime_stderr, data}, state) do
    snippet = data |> to_string() |> String.slice(0, 500)
    Logger.warning("[acp #{state.session.id}] stderr: #{snippet}")
    {:noreply, state}
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

  # ACP has no PTY — deliver the inbox knock as a real prompt frame (the body is
  # still pulled via read_messages; this is just the "you have mail" nudge).
  # NEVER send a session/prompt mid-turn: that would corrupt the live turn and
  # double-drive the agent. Always surface a UI item; send now only if idle and
  # the handshake has captured a session id, otherwise defer to post-turn.
  def handle_info(:nudge_flush, %{transport: :acp} = state) do
    from = state.nudge_froms |> MapSet.to_list() |> Enum.sort() |> Enum.join(", ")
    count = state.nudge_count
    line = Terminal.nudge_line(state.harness, count, from)

    # Upsert a structured unread item (stable id "nudge") so the human sees it
    # without spamming the timeline — it reflects the latest unread state.
    state =
      append_acp_item(state, %{
        "id" => "nudge",
        "type" => "nudge",
        "text" => line,
        "count" => count,
        "from" => from
      })

    state =
      cond do
        # SI-5: a prompt with a null sessionId must never be sent — and never
        # send mid-turn. In both cases defer the (coalesced) line to post-turn.
        Legend.Core.Acp.Connection.turn_in_flight?(state.acp) or state.acp.session_id == nil ->
          %{state | pending_nudge: line}

        true ->
          {acp, frames} = Legend.Core.Acp.Connection.prompt(state.acp, line)
          Enum.each(frames, &state.runtime.write(state.handle, &1))
          %{state | acp: acp}
      end

    {:noreply, reset_nudge(state)}
  end

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
    maybe_close_tunnel(state.tunnel)
    notify_spawner_of_exit(session, code)
    broadcast(session.id, {:session_exit, code})
    Notifications.sessions_changed()
    {:noreply, %{state | session: session, exited?: true, tunnel: nil}}
  end

  # Already ready (timer cancelled → nil) or already exited: stale timeout, no-op.
  def handle_info(:acp_handshake_timeout, %{exited?: true} = state), do: {:noreply, state}

  def handle_info(:acp_handshake_timeout, %{acp_handshake_timer: nil} = state),
    do: {:noreply, state}

  # The handshake never completed in time — treat the silent adapter as a
  # failure. Mirror the runtime-exit finalize: stop the runtime, close the
  # tunnel, mark :failed, broadcast + notify.
  def handle_info(:acp_handshake_timeout, state) do
    {:noreply, finalize_handshake_failure(state, "ACP handshake timed out")}
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
    maybe_close_tunnel(state.tunnel)
    :ok
  end

  def terminate(_reason, state) do
    maybe_close_tunnel(Map.get(state, :tunnel))
    :ok
  end

  # Append a reduced ACP item to the timeline and broadcast it for live attach.
  defp append_acp_item(state, item) do
    {timeline, [item_with_seq]} = Legend.Core.Agents.Transcript.append(state.timeline, item)
    broadcast(state.session.id, {:session_event, item_with_seq["seq"], item_with_seq})
    %{state | timeline: timeline}
  end

  # Terminal fresh launch: persist conversation_id = session.id (the handle this
  # launch already passed as --session-id) so a later transport switch resumes the
  # SAME conversation. No-op on :resume or when an id is already set; ACP captures
  # its own id from session/new (apply_effect/2), so this is terminal-only.
  defp maybe_pin_terminal_conversation_id(
         %{transport: :terminal, conversation_id: nil} = session,
         mode
       )
       when mode != :resume do
    Agents.set_session_conversation_id!(session, %{conversation_id: session.id})
  end

  defp maybe_pin_terminal_conversation_id(session, _mode), do: session

  # Handshake completed (session/new or session/load succeeded): disarm the
  # watchdog so it can't fire a spurious failure later.
  defp apply_effect({:session_ready}, state), do: cancel_handshake_watchdog(state)

  # Handshake failed (ERROR response to initialize/session_new/session_load) —
  # fatal per spec. Cancel the watchdog and finalize as a failure (mirror the
  # runtime-exit finalize).
  defp apply_effect({:handshake_failed, reason}, state) do
    state
    |> cancel_handshake_watchdog()
    |> finalize_handshake_failure(reason)
  end

  # ACP launch effects: the captured conversation id is the durable handle to
  # resume this conversation under :load — persist it on the record.
  defp apply_effect({:conversation_id, cid}, state) do
    session = Agents.set_session_conversation_id!(state.session, %{conversation_id: cid})
    %{state | session: session}
  end

  defp apply_effect({:load_capable, _}, state), do: state

  # A finished turn (agent answered session/prompt with a stopReason) becomes a
  # timeline item so live clients flip their busy flag off and reattachers see it
  # in the snapshot. Use the connection's current turn counter for a stable id.
  # Then flush ONE pending prompt — a queued user prompt first, else a deferred
  # nudge line — to keep the one-turn-at-a-time invariant.
  defp apply_effect({:turn, stop}, state) do
    state
    |> append_acp_item(%{
      "id" => "turn-#{state.acp.turn}",
      "type" => "turn",
      "stop_reason" => stop
    })
    |> flush_after_turn()
  end

  # Defensive: an unknown future effect must not crash the session.
  defp apply_effect(_effect, state), do: state

  # One-turn-at-a-time gate for ACP prompts. Mid-turn prompts queue (FIFO) and
  # drain one per turn-complete via flush_after_turn/1; otherwise send now. The
  # queue is bounded (@max_acp_prompt_queue): at the cap the incoming prompt is
  # dropped (newest-first, preserving already-accepted order) and logged.
  defp send_or_queue_prompt(state, content) do
    if Legend.Core.Acp.Connection.turn_in_flight?(state.acp) do
      if length(state.acp_prompt_queue) >= @max_acp_prompt_queue do
        Logger.warning(
          "[acp #{state.session.id}] prompt queue full (#{@max_acp_prompt_queue}); dropping incoming prompt"
        )

        state
      else
        %{state | acp_prompt_queue: state.acp_prompt_queue ++ [content]}
      end
    else
      {acp, frames} = Legend.Core.Acp.Connection.prompt(state.acp, content)
      Enum.each(frames, &state.runtime.write(state.handle, &1))
      %{state | acp: acp}
    end
  end

  # Post-turn drain: send at most ONE prompt (one turn at a time). Prefer a
  # queued user prompt; otherwise wake the agent with a deferred nudge line.
  defp flush_after_turn(%{acp_prompt_queue: [content | rest]} = state) do
    {acp, frames} = Legend.Core.Acp.Connection.prompt(state.acp, content)
    Enum.each(frames, &state.runtime.write(state.handle, &1))
    %{state | acp: acp, acp_prompt_queue: rest}
  end

  defp flush_after_turn(%{acp_prompt_queue: [], pending_nudge: line} = state)
       when is_binary(line) do
    {acp, frames} = Legend.Core.Acp.Connection.prompt(state.acp, line)
    Enum.each(frames, &state.runtime.write(state.handle, &1))
    %{state | acp: acp, pending_nudge: nil}
  end

  defp flush_after_turn(state), do: state

  defp reset_nudge(state) do
    %{state | nudge_count: 0, nudge_froms: MapSet.new(), nudge_timer: nil}
  end

  # ACP-only: arm the handshake watchdog. Terminal sessions have no handshake,
  # so leave the (nil) timer untouched.
  defp maybe_arm_handshake_watchdog(%{transport: :acp} = state) do
    ref = Process.send_after(self(), :acp_handshake_timeout, @acp_handshake_timeout_ms)
    %{state | acp_handshake_timer: ref}
  end

  defp maybe_arm_handshake_watchdog(state), do: state

  # Disarm the watchdog (idempotent: nil ref / already-fired timer are no-ops).
  defp cancel_handshake_watchdog(%{acp_handshake_timer: nil} = state), do: state

  defp cancel_handshake_watchdog(%{acp_handshake_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | acp_handshake_timer: nil}
  end

  # Finalize a handshake failure: stop the runtime, close the tunnel, mark the
  # session :failed, broadcast + notify. Mirrors the {:runtime_exit} finalize so
  # a never-handshaked session can't linger as :running. No-op if already exited.
  defp finalize_handshake_failure(%{exited?: true} = state, _reason), do: state

  defp finalize_handshake_failure(state, reason) do
    Logger.warning("[acp #{state.session.id}] #{reason}")
    state.runtime.stop(state.handle)
    maybe_close_tunnel(state.tunnel)
    session = Agents.fail_session!(state.session, %{error: reason})
    broadcast(session.id, {:session_status, :failed})
    Notifications.sessions_changed()
    %{state | session: session, exited?: true, tunnel: nil, acp_handshake_timer: nil}
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
