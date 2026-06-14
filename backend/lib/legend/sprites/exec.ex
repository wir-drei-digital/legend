defmodule Legend.Sprites.Exec do
  @moduledoc """
  Interactive PTY over the sprites.dev WSS exec endpoint. One GenServer per live
  exec; wraps `Mint.WebSocket` (the same connect/upgrade/decode structure as
  `Legend.Sprites.Proxy`). Output reaches the owner pid as `{:runtime_output,
  binary}` and termination as `{:runtime_exit, code}` — the `Legend.Core.Runtime`
  message contract, so `Legend.Runtimes.Sprites` is a thin adapter over this.

  ## Verified protocol (2026-06-14, live against api.sprites.dev)

  Connect MUST force HTTP/1.1 — the server has `enable_connect_protocol: false`,
  so WS-over-HTTP/2 (RFC 8441) fails with `:extended_connect_disabled`.

  - **Spawn:** `wss://api.sprites.dev/v1/sprites/{name}/exec` with query params
    `path=<bin>&tty=true&stdin=true&detachable=true&rows=R&cols=C` plus one
    repeated `cmd=` per argv element (`cmd=<bin>&cmd=<arg1>&...`).
  - **First server frame is TEXT** `{"type":"session_info","session_id":"<id>",...}`
    — the `session_id` is the reattach handle (persisted in `runtime_ref`).
  - **TTY output:** BINARY frames carry raw terminal bytes (no stream-id prefix).
  - **stdin:** BINARY frame with raw bytes.
  - **resize:** TEXT frame `{"type":"resize","rows":R,"cols":C}`.
  - **exit:** TEXT frame `{"type":"exit","exit_code":N}`, then a WS CLOSE (1000).
  - **Attach:** `wss://api.sprites.dev/v1/sprites/{name}/exec/{session_id}`
    (path segment, NOT a query param) — re-streams the live session; emits its
    own `session_info` then continues live output.
  """

  use GenServer

  require Logger

  alias Legend.Core.Runtime.CommandSpec

  @ws_base "wss://api.sprites.dev/v1/sprites"
  @host "api.sprites.dev"
  @port 443
  # Bounded synchronous waits during init (each tick is one 500ms recv attempt).
  @upgrade_ticks 40
  @session_info_ticks 20

  ## Public API (pure helpers — unit-tested offline)

  @doc "Base WSS exec URL for a sprite (no query string)."
  @spec exec_url(String.t()) :: String.t()
  def exec_url(name), do: "#{@ws_base}/#{name}/exec"

  @doc "Attach WSS URL for an existing exec session id."
  @spec attach_url(String.t(), String.t()) :: String.t()
  def attach_url(name, exec_id), do: "#{@ws_base}/#{name}/exec/#{exec_id}"

  @doc """
  Spawn query string for a command under a TTY. `cmd` is repeated per argv
  element; `path` is the executable. Keys are ordered for readable URLs only.
  """
  @spec spawn_query(CommandSpec.t(), keyword()) :: String.t()
  def spawn_query(%CommandSpec{cmd: bin, args: args}, opts) do
    rows = Keyword.get(opts, :rows, 24)
    cols = Keyword.get(opts, :cols, 80)

    fixed = [
      {"path", bin},
      {"tty", "true"},
      {"stdin", "true"},
      {"detachable", "true"},
      {"rows", Integer.to_string(rows)},
      {"cols", Integer.to_string(cols)}
    ]

    cmd_pairs = Enum.map([bin | args], &{"cmd", &1})

    (fixed ++ cmd_pairs)
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{URI.encode_www_form(v)}" end)
  end

  ## GenServer API

  @doc """
  Spawns `spec` under a TTY in sprite `name`. Returns `{:ok, pid, exec_id}` once
  the session_info frame yields the reattach handle. `opts` requires `:owner`;
  honours `:rows`/`:cols`.
  """
  @spec start(String.t(), CommandSpec.t(), map()) ::
          {:ok, pid(), String.t()} | {:error, String.t()}
  def start(name, %CommandSpec{} = spec, opts) do
    with {:ok, pid} <- GenServer.start_link(__MODULE__, {:spawn, name, spec, opts}) do
      {:ok, pid, GenServer.call(pid, :exec_id)}
    end
  end

  @doc "Reattaches to an existing exec session. Returns `{:ok, pid}`."
  @spec attach(String.t(), String.t(), map()) :: {:ok, pid()} | {:error, String.t()}
  def attach(name, exec_id, opts) do
    GenServer.start_link(__MODULE__, {:attach, name, exec_id, opts})
  end

  @doc """
  Runs `spec` to completion non-interactively and returns
  `{:ok, %{stdout: binary, status: integer}}`. Used for provisioning
  (detect/install) before the PTY exists. The exec process is NOT linked to the
  caller, so a SessionServer running this in `init` is unaffected by its exit.
  """
  @spec run(String.t(), CommandSpec.t(), timeout()) ::
          {:ok, %{stdout: binary(), status: integer()}} | {:error, String.t()}
  def run(name, %CommandSpec{} = spec, timeout \\ 120_000) do
    parent = self()
    ref = make_ref()
    collector = spawn(fn -> collect_run(parent, ref, "") end)

    case GenServer.start(__MODULE__, {:run, name, spec, %{owner: collector}}) do
      {:ok, pid} ->
        receive do
          {^ref, status, stdout} ->
            # The exec process stops itself after the exit frame; stop/1 is
            # tolerant of the race where it has already terminated.
            stop(pid)
            {:ok, %{stdout: stdout, status: status || 0}}
        after
          timeout ->
            stop(pid)
            {:error, "sprites exec timed out after #{timeout}ms"}
        end

      {:error, reason} ->
        {:error, "sprites exec start failed: #{inspect(reason)}"}
    end
  end

  def write(pid, data), do: GenServer.cast(pid, {:write, data})
  def resize(pid, cols, rows), do: GenServer.cast(pid, {:resize, cols, rows})

  @doc "Stops the exec. Tolerant of the race where the process already exited."
  def stop(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    else
      :ok
    end
  end

  ## GenServer callbacks

  @impl true
  def init({mode, name, arg, opts}) do
    owner = Map.fetch!(opts, :owner)

    state = %{
      name: name,
      owner: owner,
      conn: nil,
      websocket: nil,
      ref: nil,
      exec_id: nil,
      exited?: false
    }

    case token() do
      nil -> {:stop, "SPRITES_TOKEN is not set"}
      tkn -> open(mode, name, arg, opts, tkn, state)
    end
  end

  defp open(mode, name, arg, opts, tkn, state) do
    {path, known_id, await?} =
      case mode do
        :spawn -> {"/v1/sprites/#{name}/exec?#{spawn_query(arg, to_keyword(opts))}", nil, true}
        # Non-interactive one-shot: no session_info needed (output/exit flow
        # through the normal loop to the collector).
        :run -> {"/v1/sprites/#{name}/exec?#{spawn_query(arg, to_keyword(opts))}", nil, false}
        :attach -> {"/v1/sprites/#{name}/exec/#{arg}", arg, true}
      end

    headers = [{"authorization", "Bearer #{tkn}"}]

    # Force HTTP/1.1 — the server rejects WS-over-HTTP/2 (see moduledoc).
    with {:ok, conn} <- Mint.HTTP.connect(:https, @host, @port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(:wss, conn, path, headers),
         {:ok, conn, status, resp_headers} <- await_upgrade(conn, ref, [], @upgrade_ticks),
         true <- status in 100..199 || {:bad_status, status},
         {:ok, conn, ws} <- Mint.WebSocket.new(conn, ref, status, resp_headers) do
      state = %{state | conn: conn, websocket: ws, ref: ref, exec_id: known_id}
      # Spawn/attach read the leading session_info frame to capture/confirm the
      # exec id, forwarding any interleaved output to the owner.
      if await?, do: {:ok, await_session_info(state, @session_info_ticks)}, else: {:ok, state}
    else
      {:bad_status, status} ->
        {:stop, "sprites exec upgrade returned HTTP #{status}"}

      {:error, reason} ->
        {:stop, "sprites exec connect failed: #{inspect(reason)}"}

      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:stop, "sprites exec upgrade failed: #{inspect(reason)}"}
    end
  end

  @impl true
  def handle_call(:exec_id, _from, state), do: {:reply, state.exec_id, state}

  @impl true
  def handle_cast({:write, data}, state) do
    {:noreply, send_frame(state, {:binary, data})}
  end

  def handle_cast({:resize, cols, rows}, state) do
    json = Jason.encode!(%{type: "resize", rows: rows, cols: cols})
    {:noreply, send_frame(state, {:text, json})}
  end

  @impl true
  def handle_info(message, %{conn: conn, ref: ref} = state)
      when not is_nil(conn) and not is_nil(ref) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        handle_responses(responses, ref, %{state | conn: conn})

      {:error, conn, reason, _partial} ->
        Logger.error("[Sprites.Exec] stream error: #{inspect(reason)}")
        exit_owner(state, nil)
        {:stop, {:shutdown, reason}, %{state | conn: conn, exited?: true}}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{conn: conn}) when not is_nil(conn) do
    Mint.HTTP.close(conn)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Frame handling

  defp handle_responses([], _ref, state), do: {:noreply, state}

  defp handle_responses([{:data, ref, raw} | rest], ref, state) do
    case Mint.WebSocket.decode(state.websocket, raw) do
      {:ok, ws, frames} ->
        state = Enum.reduce(frames, %{state | websocket: ws}, &dispatch_frame/2)

        if state.exited? do
          {:stop, :normal, state}
        else
          handle_responses(rest, ref, state)
        end

      {:error, ws, reason} ->
        Logger.error("[Sprites.Exec] decode error: #{inspect(reason)}")
        {:stop, {:shutdown, reason}, %{state | websocket: ws}}
    end
  end

  defp handle_responses([{:done, _ref} | rest], ref, state),
    do: handle_responses(rest, ref, state)

  defp handle_responses([_other | rest], ref, state),
    do: handle_responses(rest, ref, state)

  # Raw terminal output.
  defp dispatch_frame({:binary, data}, state) do
    send(state.owner, {:runtime_output, data})
    state
  end

  # Control frames: session_info (capture id), exit (terminate), others ignored.
  defp dispatch_frame({:text, json}, state) do
    case Jason.decode(json) do
      {:ok, %{"type" => "session_info", "session_id" => id}} ->
        %{state | exec_id: state.exec_id || to_string(id)}

      {:ok, %{"type" => "exit", "exit_code" => code}} ->
        exit_owner(state, code)
        %{state | exited?: true}

      _ ->
        state
    end
  end

  defp dispatch_frame({:close, _code, _reason}, state) do
    unless state.exited?, do: exit_owner(state, nil)
    %{state | exited?: true}
  end

  defp dispatch_frame(_frame, state), do: state

  defp exit_owner(%{exited?: true}, _code), do: :ok
  defp exit_owner(state, code), do: send(state.owner, {:runtime_exit, code})

  # Collector for run/3: accumulate output, report {ref, status, stdout} on exit.
  defp collect_run(parent, ref, acc) do
    receive do
      {:runtime_output, data} -> collect_run(parent, ref, acc <> data)
      {:runtime_exit, code} -> send(parent, {ref, code, acc})
    end
  end

  ## Synchronous init helpers (mirror Legend.Sprites.Proxy)

  defp await_upgrade(_conn, _ref, _acc, 0), do: {:error, :upgrade_timeout}

  defp await_upgrade(conn, ref, acc, ticks) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            acc = acc ++ responses

            if Enum.any?(acc, &match?({:status, ^ref, _}, &1)) and
                 Enum.any?(acc, &match?({:headers, ^ref, _}, &1)) and
                 Enum.any?(acc, &match?({:done, ^ref}, &1)) do
              {:status, _, status} = Enum.find(acc, &match?({:status, ^ref, _}, &1))
              {:headers, _, headers} = Enum.find(acc, &match?({:headers, ^ref, _}, &1))
              {:ok, conn, status, headers}
            else
              await_upgrade(conn, ref, acc, ticks - 1)
            end

          {:error, _conn, reason, _} ->
            {:error, reason}

          :unknown ->
            await_upgrade(conn, ref, acc, ticks - 1)
        end
    after
      500 -> await_upgrade(conn, ref, acc, ticks - 1)
    end
  end

  # Block until exec_id is known (session_info), forwarding any output that
  # arrives first. Returns the (possibly id-less) state when the budget is spent.
  defp await_session_info(%{exec_id: id} = state, _ticks) when not is_nil(id), do: state
  defp await_session_info(state, 0), do: state

  defp await_session_info(state, ticks) do
    receive do
      message ->
        case Mint.WebSocket.stream(state.conn, message) do
          {:ok, conn, responses} ->
            state = reduce_responses(responses, %{state | conn: conn})
            await_session_info(state, ticks - 1)

          {:error, conn, reason, _} ->
            Logger.error("[Sprites.Exec] session_info stream error: #{inspect(reason)}")
            %{state | conn: conn}

          :unknown ->
            await_session_info(state, ticks - 1)
        end
    after
      500 -> await_session_info(state, ticks - 1)
    end
  end

  defp reduce_responses(responses, state) do
    Enum.reduce(responses, state, fn
      {:data, _ref, raw}, st ->
        case Mint.WebSocket.decode(st.websocket, raw) do
          {:ok, ws, frames} -> Enum.reduce(frames, %{st | websocket: ws}, &dispatch_frame/2)
          {:error, ws, _} -> %{st | websocket: ws}
        end

      _other, st ->
        st
    end)
  end

  ## Send path

  defp send_frame(%{conn: conn, websocket: ws, ref: ref} = state, frame) do
    with {:ok, ws, data} <- Mint.WebSocket.encode(ws, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      %{state | conn: conn, websocket: ws}
    else
      {:error, ws_or_conn, reason} ->
        Logger.error("[Sprites.Exec] send error: #{inspect(reason)}")
        maybe_update_ws(state, ws_or_conn)
    end
  end

  defp maybe_update_ws(state, %Mint.WebSocket{} = ws), do: %{state | websocket: ws}
  defp maybe_update_ws(state, conn), do: %{state | conn: conn}

  defp to_keyword(opts) do
    [rows: opts[:rows] || 24, cols: opts[:cols] || 80]
  end

  defp token, do: Application.get_env(:legend, :sprites_token)
end
