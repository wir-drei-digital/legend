# Library + Messaging over the Reverse Tunnel (Spec 2b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a cloud (`:api`) agent a full Legend participant — message other agents and read/write the shared library — by bringing the Spec-1 reverse tunnel to life and wiring it into the session.

**Architecture:** Two phases. **Phase 1** retires the tunnel risk: cross-compile the `legend-bridge` for sprites, fix the carrier's HTTP/2 bug, deliver/launch the bridge over the *verified* WSS exec, add backend-side carrier reconnect, and run Spec 1's deferred end-to-end check. **Phase 2** delivers the payoff: four `library_*` MCP tools on `/api/mcp`, and `SessionServer` opening the tunnel for tunnel-declaring runtimes, rewriting the agent's MCP URL to the tunnel's loopback `base_url`, injecting the session token + an `:api` library primer, and re-opening on resume.

**Tech Stack:** Elixir/Phoenix/Ash; `Mint.WebSocket` (carrier + exec, both HTTP/1.1-forced); Rust + `cargo-zigbuild` (musl-static bridge); the Spec-1 `Legend.Core.Tunnel`/`SpriteProxy`/mux and the 2a `Legend.Sprites.Exec`/`Client`. `SPRITES_TOKEN` in `backend/.env`.

**Spec:** `docs/superpowers/specs/2026-06-14-sprites-library-messaging-over-tunnel-design.md`.

---

## File structure

**Phase 1 — bring the existing tunnel live (mostly fixes):**
- `bridge/` — cross-compile to `x86_64-unknown-linux-musl`; `justfile` gains `build-bridge`; output → `backend/priv/tunnel/legend-bridge-x86_64-linux` (gitignored).
- `backend/lib/legend/sprites/proxy.ex` — force `protocols: [:http1]` on the carrier connect.
- `backend/lib/legend/tunnels/sprite_proxy.ex` — generic `%{session_id}` target; deliver via fs API (probe-first), launch via `Exec.run`; `open` starts the Server which owns the carrier.
- `backend/lib/legend/tunnels/sprite_proxy/server.ex` — owns the carrier: connect, monitor, reconnect-on-drop with backoff, reset streams. Injected `:connector` seam for offline testing.

**Phase 2 — library + messaging wiring (new + edits):**
- `backend/lib/legend/core/library/tools.ex` — **new**: four `library_*` MCP tools.
- `backend/lib/legend_web/controllers/mcp_controller.ex` — compose `[Signals.Tools, Library.Tools]`.
- `backend/lib/legend/core/library.ex` — `primer/1` (mode-aware).
- `backend/lib/legend/core/agents/session_server.ex` — open/close tunnel, thread `base_url` through `build_opts`/`platform_env`, resume re-open.
- `backend/test/support/tunnels/test.ex` — **new**: `Legend.Tunnels.Test` double.
- `backend/config/test.exs` — register the test tunnel.
- `docs/ARCHITECTURE.md` — mark library/messaging-over-tunnel built.

---

# Phase 1 — Tunnel bring-up

### Task 1: Cross-compile the bridge to x86_64-linux-musl

**Files:**
- Modify: `justfile` (root)
- Modify: `.gitignore` (root) and/or `backend/.gitignore`
- Build output: `backend/priv/tunnel/legend-bridge-x86_64-linux`

> No unit test — this is a build/tooling task; correctness is the `file` check below + the Task 6 live e2e. The bridge source already supports sequential carrier reconnection (`bridge/src/main.rs` carrier loop), so no Rust changes are needed.

- [ ] **Step 1: Add the musl target + cross-build toolchain**

Run:
```bash
rustup target add x86_64-unknown-linux-musl
cargo install cargo-zigbuild
zig version || brew install zig   # cargo-zigbuild needs zig on PATH
```
Expected: target installed; `cargo-zigbuild` available; a `zig version` prints (e.g. `0.15.x`). If `cargo-zigbuild` rejects the zig version, fall back to `brew install FiloSottile/musl-cross/musl-cross` and use `CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=x86_64-linux-musl-gcc cargo build --target x86_64-unknown-linux-musl --release` in Step 2 instead.

- [ ] **Step 2: Build the static binary**

Run:
```bash
cd bridge && cargo zigbuild --release --target x86_64-unknown-linux-musl
```
Expected: builds clean; binary at `bridge/target/x86_64-unknown-linux-musl/release/legend-bridge`.

- [ ] **Step 3: Place it where the provider reads it**

`Legend.Tunnels.SpriteProxy.read_bridge/0` reads `:code.priv_dir(:legend)/tunnel/legend-bridge-x86_64-linux`. Run:
```bash
mkdir -p backend/priv/tunnel
cp bridge/target/x86_64-unknown-linux-musl/release/legend-bridge backend/priv/tunnel/legend-bridge-x86_64-linux
file backend/priv/tunnel/legend-bridge-x86_64-linux
```
Expected: `ELF 64-bit LSB executable, x86-64, … statically linked, …` (must say x86-64 and statically linked).

- [ ] **Step 4: Add the `just build-bridge` task**

In the root `justfile`, add (after `package-backend`):
```make
# Cross-compile the in-sprite reverse-tunnel bridge (static x86_64 musl)
build-bridge:
    rustup target add x86_64-unknown-linux-musl
    cd bridge && cargo zigbuild --release --target x86_64-unknown-linux-musl
    mkdir -p backend/priv/tunnel
    cp bridge/target/x86_64-unknown-linux-musl/release/legend-bridge backend/priv/tunnel/legend-bridge-x86_64-linux
    @file backend/priv/tunnel/legend-bridge-x86_64-linux
```

- [ ] **Step 5: Gitignore the built binary**

Add to `backend/.gitignore`:
```
/priv/tunnel/legend-bridge-*
```

- [ ] **Step 6: Commit**

```bash
git add justfile backend/.gitignore
git commit -m "build(tunnel): just build-bridge cross-compiles the musl bridge for sprites

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Fix the carrier HTTP/1.1 bug

**Files:**
- Modify: `backend/lib/legend/sprites/proxy.ex`

> The carrier (proxy WSS) hits `%Mint.WebSocketError{reason: :extended_connect_disabled}` against the live API because Mint negotiates HTTP/2 and sprites disables RFC-8441 extended CONNECT. Same fix already applied to `Legend.Sprites.Exec` in 2a. No unit test (behavior is verified in Task 6); the change is a one-argument addition.

- [ ] **Step 1: Force HTTP/1.1 on connect**

In `backend/lib/legend/sprites/proxy.ex`, find the connect in `do_open/2`:
```elixir
    with {:ok, conn} <- Mint.HTTP.connect(:https, @connect_host, @connect_port),
```
Change to:
```elixir
    with {:ok, conn} <-
           Mint.HTTP.connect(:https, @connect_host, @connect_port, protocols: [:http1]),
```

- [ ] **Step 2: Compile**

Run: `cd backend && mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add backend/lib/legend/sprites/proxy.ex
git commit -m "fix(tunnel): force HTTP/1.1 on the carrier WSS (sprites rejects WS-over-h2)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Deliver + launch the bridge over verified transports

**Files:**
- Modify: `backend/lib/legend/tunnels/sprite_proxy.ex`

> The current `ensure_bridge/2` launches via `Client.exec/2` (REST). Live probing in 2a showed the REST exec returns the raw binary stream protocol, not JSON, and its body shape is a guess — unreliable for launching. Switch the launch to the **verified** WSS `Legend.Sprites.Exec.run/3`, guard against double-launch, and keep the binary upload on the sprites **fs API** (probe-first).

- [ ] **Step 1: Probe the fs API round-trips a binary** (live, gated on `SPRITES_TOKEN`)

```bash
cd backend && cat > /tmp/fs_probe.exs <<'EOF'
alias Legend.Sprites.{Client, Exec}
alias Legend.Core.Runtime.CommandSpec
name = "legend-fs-probe"
IO.inspect(Client.create_sprite(name) |> elem(0), label: "create")
Process.sleep(1500)
bin = :crypto.strong_rand_bytes(2048)
IO.inspect(Client.write_file(name, "/tmp/probe.bin", bin) |> elem(0), label: "write_file")
IO.inspect(Client.chmod(name, "/tmp/probe.bin", "0755") |> elem(0), label: "chmod")
{:ok, %{stdout: out}} = Exec.run(name, %CommandSpec{cmd: "sh", args: ["-c", "wc -c </tmp/probe.bin"], io: :pipes})
IO.puts("size in sprite (expect 2048): #{String.trim(out)}")
IO.inspect(Client.delete_sprite(name) |> elem(0), label: "delete")
EOF
mix run /tmp/fs_probe.exs 2>&1 | grep -vE "^\[debug\]|run_query|^\[90m|^$" | tail -10
```
Expected: `write_file`/`chmod` return `:ok` and "size in sprite (expect 2048): 2048". **If the fs API fails or corrupts the binary**, switch upload to the base64-over-exec fallback (see spec §1.3; requires a non-TTY mode in `Legend.Sprites.Exec`) and note it in the commit; otherwise proceed with the fs API.

- [ ] **Step 2: Rework `ensure_bridge/2`** in `backend/lib/legend/tunnels/sprite_proxy.ex`

Add the alias and replace `ensure_bridge/2` + the `Client.exec` launch with:
```elixir
  alias Legend.Core.Runtime.CommandSpec
  alias Legend.Sprites.{Client, Exec, Proxy}

  defp ensure_bridge(name, bin) do
    with {:ok, _} <- Client.write_file(name, @bridge_dest, bin),
         {:ok, %{status: 0}} <- launch_bridge(name) do
      :ok
    else
      {:ok, %{status: s, stdout: out}} -> {:error, "bridge launch failed (#{s}): #{out}"}
      {:error, reason} -> {:error, "bridge delivery failed: #{reason}"}
    end
  end

  # chmod + launch over the verified WSS exec. setsid detaches the bridge from
  # the exec session so it survives; pgrep guards against a second launch (e.g.
  # on resume the bridge is already running and the ports are bound).
  defp launch_bridge(name) do
    cmd =
      "chmod +x #{@bridge_dest} && " <>
        "(pgrep -x legend-bridge >/dev/null 2>&1 || setsid #{@bridge_dest} >/tmp/bridge.log 2>&1 &) ; " <>
        "sleep 0.3"

    Exec.run(name, %CommandSpec{cmd: "sh", args: ["-c", cmd], io: :pipes})
  end
```
(Remove the old `Client.chmod` + `Client.exec` calls. Keep the existing `alias Legend.Sprites.{Client, Proxy}` merged into the line above.)

- [ ] **Step 3: Compile**

Run: `cd backend && mix compile --warnings-as-errors` → clean.

- [ ] **Step 4: Live-verify the launch** (gated, manual; full e2e is Task 6)

```bash
cd backend && cat > /tmp/launch_probe.exs <<'EOF'
alias Legend.Sprites.{Client, Exec}
alias Legend.Core.Runtime.CommandSpec
name = "legend-launch-probe"
Client.create_sprite(name); Process.sleep(1500)
bin = File.read!(Path.join([:code.priv_dir(:legend), "tunnel", "legend-bridge-x86_64-linux"]))
:ok = Legend.Tunnels.SpriteProxy.__ensure_bridge__(name, bin)  # see note
{:ok, %{stdout: out}} = Exec.run(name, %CommandSpec{cmd: "sh", args: ["-c", "pgrep -x legend-bridge && echo RUNNING"], io: :pipes})
IO.puts(out)
Client.delete_sprite(name)
EOF
```
> NOTE: `ensure_bridge/2` is private. For this probe either temporarily expose a `@doc false def __ensure_bridge__/2` delegating to it, or inline the upload+launch in the script. Expected: output contains `RUNNING`. Remove any temporary export before committing.

- [ ] **Step 5: Commit**

```bash
git add backend/lib/legend/tunnels/sprite_proxy.ex
git commit -m "feat(tunnel): deliver bridge via fs API, launch via verified WSS exec (guarded)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Server owns the carrier — connect, monitor, reconnect-on-drop

**Files:**
- Modify: `backend/lib/legend/tunnels/sprite_proxy/server.ex`
- Modify: `backend/lib/legend/tunnels/sprite_proxy.ex`
- Test: `backend/test/legend/tunnels/sprite_proxy_server_test.exs`

> Sprites hibernate when idle → the carrier WSS drops. The bridge already accepts sequential carriers (`main.rs`). Make the backend reconnect: the `Server` owns the carrier (connects it, traps its exit, reconnects with backoff, resets in-flight streams). A `:connector` seam lets us test reconnection offline without a live sprite.

- [ ] **Step 1: Write the failing test** at `backend/test/legend/tunnels/sprite_proxy_server_test.exs`

```elixir
defmodule Legend.Tunnels.SpriteProxy.ServerTest do
  use ExUnit.Case, async: true
  alias Legend.Tunnels.SpriteProxy.Server

  # A fake carrier: a process that lives until told to die. The connector records
  # each connect attempt to the test pid and returns a fresh fake carrier.
  defp fake_connector(test) do
    fn _sprite, _port, _server ->
      pid = spawn(fn -> Process.sleep(:infinity) end)
      send(test, {:connected, pid})
      {:ok, pid}
    end
  end

  test "connects a carrier on start and reconnects when it drops" do
    test = self()

    {:ok, _srv} =
      Server.start_link(
        target_port: 0,
        sprite: "s1",
        control_port: 9000,
        connector: fake_connector(test),
        reconnect_base_ms: 10
      )

    assert_receive {:connected, carrier1}, 500
    Process.exit(carrier1, :kill)
    assert_receive {:connected, carrier2}, 1000
    assert carrier2 != carrier1
  end
end
```

- [ ] **Step 2: Run, verify it fails**

Run: `cd backend && mix test test/legend/tunnels/sprite_proxy_server_test.exs`
Expected: FAIL (Server doesn't accept `:connector`/`:sprite`/`:control_port`, doesn't connect or reconnect).

- [ ] **Step 3: Rewrite `Server` to own the carrier** — `backend/lib/legend/tunnels/sprite_proxy/server.ex`

Replace `start_link/1`, `init/1`, the `set_out` cast, and add carrier ownership. Keep all `handle_frame`/`handle_info({:tcp,…})`/`drop` logic unchanged:

```elixir
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      target_port: Keyword.fetch!(opts, :target_port),
      sprite: Keyword.fetch!(opts, :sprite),
      control_port: Keyword.fetch!(opts, :control_port),
      connector: Keyword.get(opts, :connector, &default_connect/3),
      reconnect_base_ms: Keyword.get(opts, :reconnect_base_ms, 500),
      out: nil,
      attempt: 0,
      buffer: "",
      streams: %{},
      ids: %{}
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect_carrier(state)}

  # Carrier (a linked process) died — reset streams and reconnect with backoff.
  @impl true
  def handle_info({:EXIT, pid, _reason}, %{out: pid} = state) do
    Enum.each(Map.keys(state.streams), &close_sock(state, &1))
    state = %{state | out: nil, streams: %{}, ids: %{}, buffer: ""}
    delay = state.reconnect_base_ms * (state.attempt + 1)
    Process.send_after(self(), :reconnect, delay)
    {:noreply, %{state | attempt: state.attempt + 1}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(:reconnect, state), do: {:noreply, connect_carrier(state)}
```

Add the connect helpers + replace the old `set_out`/`out` plumbing (the carrier now pushes `{:carrier_data, _}` to the Server, and the Server pushes `{:carrier_out, _}` to `state.out`):
```elixir
  defp connect_carrier(state) do
    case state.connector.(state.sprite, state.control_port, self()) do
      {:ok, carrier} -> %{state | out: carrier, attempt: 0}
      {:error, reason} ->
        require Logger
        Logger.warning("[SpriteProxy.Server] carrier connect failed: #{inspect(reason)}")
        delay = state.reconnect_base_ms * (state.attempt + 1)
        Process.send_after(self(), :reconnect, delay)
        %{state | attempt: state.attempt + 1}
    end
  end

  defp default_connect(sprite, control_port, server),
    do: Legend.Sprites.Proxy.connect(sprite, control_port, server)

  defp close_sock(state, id) do
    case Map.get(state.streams, id) do
      nil -> :ok
      sock -> :gen_tcp.close(sock)
    end
  end
```
Delete the now-unused `set_out/2` cast and its `handle_cast`. The `out/2` private helper that sends `{:carrier_out, …}` stays as-is.

> `Legend.Sprites.Proxy.connect/3` uses `GenServer.start_link`, so the carrier links to this Server — `trap_exit` turns its death into the `{:EXIT, …}` above. Good.

- [ ] **Step 4: Update `SpriteProxy.open/1`** — `backend/lib/legend/tunnels/sprite_proxy.ex`

The Server now owns the carrier, and the target is the generic `%{session_id}`:
```elixir
  @impl true
  def open(%{session_id: name}) do
    with {:ok, bin} <- read_bridge(),
         :ok <- ensure_bridge(name, bin),
         {:ok, srv} <-
           Server.start_link(
             target_port: endpoint_port(),
             sprite: name,
             control_port: @control_port
           ) do
      {:ok, %{base_url: "http://127.0.0.1:#{@data_port}", handle: %{server: srv}}}
    end
  end

  @impl true
  def close(%{server: server}) do
    stop(server)
    :ok
  end
```
(Remove the old `Proxy.connect` + `Server.set_out` lines from `open`, and the `carrier` key from the handle/close.)

- [ ] **Step 5: Run the test, verify it passes**

Run: `cd backend && mix test test/legend/tunnels/sprite_proxy_server_test.exs` → PASS.
Also: `cd backend && mix test test/legend/tunnels/ test/legend/core/tunnel/` → green (existing mux/codec tests unaffected).

- [ ] **Step 6: Commit**

```bash
git add backend/lib/legend/tunnels/sprite_proxy/server.ex backend/lib/legend/tunnels/sprite_proxy.ex backend/test/legend/tunnels/sprite_proxy_server_test.exs
git commit -m "feat(tunnel): Server owns the carrier with reconnect-on-drop; generic session_id target

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Phase-1 live end-to-end (Spec 1's deferred verification)

**Files:** none committed (a gated verification script under `/tmp`).

> This is the Phase-1 exit gate: reach the local backend *from inside a real sprite*. Requires the backend running locally (`just dev` or `cd backend && mix phx.server`) and `SPRITES_TOKEN` set. The bridge must be built (Task 1).

- [ ] **Step 1: Run the e2e** (backend running on :4100)

```bash
cd backend && cat > /tmp/tunnel_e2e.exs <<'EOF'
alias Legend.Sprites.{Client, Exec}
alias Legend.Core.Runtime.CommandSpec
alias Legend.Tunnels.SpriteProxy

name = "legend-tunnel-e2e"
Client.create_sprite(name); Process.sleep(1500)
{:ok, %{base_url: url}} = SpriteProxy.open(%{session_id: name})
IO.puts("base_url: #{url}")

run = fn label, sh ->
  {:ok, %{stdout: out}} = Exec.run(name, %CommandSpec{cmd: "sh", args: ["-c", sh], io: :pipes}, 30_000)
  IO.puts("[#{label}] #{String.slice(out, 0, 200)}")
end

run.("health", "curl -s #{url}/api/health")
run.("concurrent", "curl -s #{url}/api/health & curl -s #{url}/api/health & wait")

IO.inspect(Client.delete_sprite(name) |> elem(0), label: "delete")
EOF
mix run /tmp/tunnel_e2e.exs 2>&1 | grep -vE "^\[debug\]|run_query|^\[90m|^$" | tail -15
```
Expected: `[health]` prints the backend's health JSON (e.g. `{"status":"ok"...}`); `[concurrent]` prints two health bodies. **Phase 1 is done when the backend's own JSON comes back from inside the cloud sprite with nothing publicly exposed.**

- [ ] **Step 2: (Optional) verify reconnect live** — kill the carrier mid-session and confirm a subsequent curl still succeeds. This is exercised structurally by Task 4's offline test; a live check is nice-to-have, not a gate.

---

# Phase 2 — Library + messaging over the tunnel

### Task 6: Library MCP tools

**Files:**
- Create: `backend/lib/legend/core/library/tools.ex`
- Test: `backend/test/legend/core/library/tools_test.exs`

- [ ] **Step 1: Write the failing test** at `backend/test/legend/core/library/tools_test.exs`

```elixir
defmodule Legend.Core.Library.ToolsTest do
  use ExUnit.Case, async: false
  alias Legend.Core.Library.Tools

  setup do
    root = Path.join(System.tmp_dir!(), "lib-tools-#{System.unique_integer([:positive])}")
    Application.put_env(:legend, :library_default_root, root)
    Legend.Core.Library.ensure_seeded!(root)
    on_exit(fn -> File.rm_rf(root); Application.delete_env(:legend, :library_default_root) end)
    :ok
  end

  test "list/0 advertises the four library tools" do
    names = Enum.map(Tools.list(), & &1.name)
    assert names == ["library_list", "library_read", "library_write", "library_delete"]
  end

  test "write then read round-trips through the chokepoint" do
    assert {:ok, _} = Tools.dispatch("library_write", %{"path" => "knowledge/n.md", "content" => "hi"})
    assert {:ok, "hi"} = Tools.dispatch("library_read", %{"path" => "knowledge/n.md"})
  end

  test "library_list returns the tree as text" do
    assert {:ok, text} = Tools.dispatch("library_list", %{})
    assert text =~ "knowledge"
  end

  test "delete removes a file" do
    Tools.dispatch("library_write", %{"path" => "artifacts/a.txt", "content" => "x"})
    assert {:ok, _} = Tools.dispatch("library_delete", %{"path" => "artifacts/a.txt"})
    assert {:error, msg} = Tools.dispatch("library_read", %{"path" => "artifacts/a.txt"})
    assert is_binary(msg)
  end

  test "path escape is rejected without leaking the absolute path" do
    assert {:error, msg} = Tools.dispatch("library_read", %{"path" => "../../etc/passwd"})
    assert msg =~ "escapes" or msg =~ "outside"
    refute msg =~ System.tmp_dir!()
  end

  test "unknown tool errors" do
    assert {:error, _} = Tools.dispatch("nope", %{})
  end
end
```

- [ ] **Step 2: Run, verify it fails**

Run: `cd backend && mix test test/legend/core/library/tools_test.exs` → FAIL (module undefined).

- [ ] **Step 3: Implement** `backend/lib/legend/core/library/tools.ex`

```elixir
defmodule Legend.Core.Library.Tools do
  @moduledoc """
  MCP tool surface for the shared library — the cloud-agent counterpart to the
  `$LEGEND_LIBRARY` filesystem a local agent gets. Pure dispatch from (tool name,
  string-keyed args) to {:ok, text} | {:error, text}; every path goes through the
  `Legend.Core.Library` containment chokepoint. The MCP controller supplies auth.
  """

  alias Legend.Core.Library

  def list do
    [
      %{
        name: "library_list",
        description: "List the shared library tree (knowledge/, skills/, artifacts/).",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "library_read",
        description: "Read a text file from the shared library.",
        inputSchema: %{
          type: "object",
          properties: %{path: %{type: "string", description: "relative path, e.g. knowledge/x.md"}},
          required: ["path"]
        }
      },
      %{
        name: "library_write",
        description: "Create or overwrite a text file in the shared library.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "relative path"},
            content: %{type: "string", description: "file contents"}
          },
          required: ["path", "content"]
        }
      },
      %{
        name: "library_delete",
        description: "Delete a file from the shared library.",
        inputSchema: %{
          type: "object",
          properties: %{path: %{type: "string", description: "relative path"}},
          required: ["path"]
        }
      }
    ]
  end

  def dispatch("library_list", _args) do
    {:ok, format_tree(Library.list_tree())}
  end

  def dispatch("library_read", %{"path" => path}) when is_binary(path) do
    case Library.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  def dispatch("library_write", %{"path" => path, "content" => content})
      when is_binary(path) and is_binary(content) do
    case Library.write(path, content) do
      :ok -> {:ok, "Wrote #{path}."}
      {:ok, _} -> {:ok, "Wrote #{path}."}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  def dispatch("library_delete", %{"path" => path}) when is_binary(path) do
    case Library.delete(path) do
      :ok -> {:ok, "Deleted #{path}."}
      {:ok, _} -> {:ok, "Deleted #{path}."}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  def dispatch(name, _args), do: {:error, "unknown tool or missing required arguments: #{name}"}

  # Sanitized messages — never leak absolute paths or internals.
  defp message(:unsafe_path), do: "path escapes the library root"
  defp message(:not_text), do: "not a text file"
  defp message(:enoent), do: "no such file"
  defp message(reason) when is_atom(reason), do: "library error: #{reason}"
  defp message(reason), do: "library error: #{inspect(reason)}"

  defp format_tree(tree), do: tree |> List.wrap() |> Enum.map_join("\n", &format_entry/1)

  defp format_entry(%{path: path, type: type}), do: "#{type}\t#{path}"
  defp format_entry(%{"path" => path, "type" => type}), do: "#{type}\t#{path}"
  defp format_entry(other), do: inspect(other)
end
```

> NOTE: `Library.list_tree/0` returns whatever `Legend.Storage.LocalDisk.list_tree/1` produces. Before finalizing `format_tree/1`, run `cd backend && mix run -e 'IO.inspect Legend.Core.Library.list_tree()'` and adjust `format_entry/1` to the actual shape (it returns a list of entries with a path + type/kind). The test asserts only that the text contains `"knowledge"`, so any readable serialization passes.

- [ ] **Step 4: Run, verify it passes**

Run: `cd backend && mix test test/legend/core/library/tools_test.exs` → PASS (6 tests). Adjust `format_entry/1` if the tree shape differs.

- [ ] **Step 5: Commit**

```bash
git add backend/lib/legend/core/library/tools.ex backend/test/legend/core/library/tools_test.exs
git commit -m "feat(library): library_list/read/write/delete MCP tools (chokepoint-guarded)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Compose library tools into the MCP endpoint

**Files:**
- Modify: `backend/lib/legend_web/controllers/mcp_controller.ex`
- Test: `backend/test/legend_web/controllers/mcp_library_test.exs`

- [ ] **Step 1: Write the failing test** at `backend/test/legend_web/controllers/mcp_library_test.exs`

```elixir
defmodule LegendWeb.MCPLibraryTest do
  use LegendWeb.ConnCase, async: false
  alias Legend.Core.Agents

  setup do
    root = Path.join(System.tmp_dir!(), "mcp-lib-#{System.unique_integer([:positive])}")
    Application.put_env(:legend, :library_default_root, root)
    Legend.Core.Library.ensure_seeded!(root)
    on_exit(fn -> File.rm_rf(root); Application.delete_env(:legend, :library_default_root) end)

    session = Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})
    {:ok, token: session.mcp_token}
  end

  defp rpc(conn, token, method, params) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
    |> json_response(200)
  end

  test "tools/list includes the library tools", %{conn: conn, token: token} do
    names = rpc(conn, token, "tools/list", %{})["result"]["tools"] |> Enum.map(& &1["name"])
    assert "send_message" in names
    assert "library_write" in names and "library_read" in names
  end

  test "library_write then library_read round-trips via MCP", %{conn: conn, token: token} do
    w = rpc(conn, token, "tools/call", %{"name" => "library_write", "arguments" => %{"path" => "knowledge/m.md", "content" => "tunneled"}})
    refute w["result"]["isError"]

    r = rpc(conn, token, "tools/call", %{"name" => "library_read", "arguments" => %{"path" => "knowledge/m.md"}})
    assert hd(r["result"]["content"])["text"] == "tunneled"
  end
end
```

- [ ] **Step 2: Run, verify it fails**

Run: `cd backend && mix test test/legend_web/controllers/mcp_library_test.exs` → FAIL (library tools not in the list / not dispatched).

- [ ] **Step 3: Compose providers in** `backend/lib/legend_web/controllers/mcp_controller.ex`

Add the alias and a provider list near the top:
```elixir
  alias Legend.Core.Library
  alias Legend.Core.Signals.Tools

  @tool_providers [Tools, Library.Tools]
```
Replace the `tools/list` and `tools/call` dispatch clauses:
```elixir
  defp dispatch("tools/list", _params, _session) do
    {:ok, %{tools: Enum.flat_map(@tool_providers, & &1.list())}}
  end

  defp dispatch("tools/call", %{"name" => name} = params, session) do
    args = params["arguments"] || %{}

    result =
      case provider_for(name) do
        Legend.Core.Signals.Tools -> Tools.dispatch(session, name, args)
        Legend.Core.Library.Tools -> Library.Tools.dispatch(name, args)
        nil -> {:error, "unknown tool: #{name}"}
      end

    case result do
      {:ok, text} -> {:ok, %{content: [%{type: "text", text: text}], isError: false}}
      {:error, text} -> {:ok, %{content: [%{type: "text", text: text}], isError: true}}
    end
  end
```
Add the resolver:
```elixir
  defp provider_for(name) do
    Enum.find(@tool_providers, fn mod -> Enum.any?(mod.list(), &(&1.name == name)) end)
  end
```
(`Signals.Tools.dispatch/3` takes the session; `Library.Tools.dispatch/2` does not — the library is token-scoped, not session-identity-scoped.)

- [ ] **Step 4: Run, verify it passes**

Run: `cd backend && mix test test/legend_web/controllers/mcp_library_test.exs` → PASS.
Also: `cd backend && mix test test/legend/core/signals/ test/legend_web/` → green (existing MCP/signal tests unaffected).

- [ ] **Step 5: Commit**

```bash
git add backend/lib/legend_web/controllers/mcp_controller.ex backend/test/legend_web/controllers/mcp_library_test.exs
git commit -m "feat(mcp): compose library tools into /api/mcp alongside the signal tools

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Mode-aware library primer

**Files:**
- Modify: `backend/lib/legend/core/library.ex`
- Modify: `backend/lib/legend/core/agents/session_server.ex` (one call site)
- Test: `backend/test/legend/core/library_test.exs` (create if absent)

- [ ] **Step 1: Write the failing test** at `backend/test/legend/core/library_test.exs`

```elixir
defmodule Legend.Core.LibraryTest do
  use ExUnit.Case, async: true
  alias Legend.Core.Library

  test "primer(:path) mentions the filesystem path" do
    assert Library.primer(:path) =~ "$LEGEND_LIBRARY"
  end

  test "primer(:api) tells the agent to use the library MCP tools" do
    p = Library.primer(:api)
    assert p =~ "library_read" or p =~ "MCP tool"
    refute p =~ "$LEGEND_LIBRARY"
  end
end
```

- [ ] **Step 2: Run, verify it fails**

Run: `cd backend && mix test test/legend/core/library_test.exs` → FAIL (`primer/1` undefined).

- [ ] **Step 3: Make `primer` mode-aware** in `backend/lib/legend/core/library.ex`

Replace the existing `def primer do … end` with:
```elixir
  def primer(mode \\ :path)

  def primer(:path) do
    """
    A shared Legend library lives at $LEGEND_LIBRARY with knowledge/, skills/, and \
    artifacts/ directories (each has a README with its conventions). Before solving \
    a problem from scratch, check the library for existing knowledge or skills. When \
    you produce something reusable (a script, a how-to, a finding), save it there \
    with a descriptive kebab-case filename.
    """
  end

  def primer(:api) do
    """
    A shared Legend library (knowledge/, skills/, artifacts/) is available through \
    the library_list / library_read / library_write / library_delete MCP tools. \
    Before solving a problem from scratch, library_list and library_read to check for \
    existing knowledge or skills. When you produce something reusable, library_write \
    it with a descriptive kebab-case path (e.g. artifacts/my-result.md).
    """
  end
```
(The default arg keeps existing arity-0 callers working, but update the one in `SessionServer` explicitly in Step 4.)

- [ ] **Step 4: Use `primer(:path)` at the SessionServer call site**

In `backend/lib/legend/core/agents/session_server.ex`, `build_opts(session, mode, %{library: :path})` currently calls `Legend.Core.Library.primer()`. Change it to `Legend.Core.Library.primer(:path)` (explicit; the `:api` branch is added in Task 9).

- [ ] **Step 5: Run, verify it passes**

Run: `cd backend && mix test test/legend/core/library_test.exs` → PASS. `cd backend && mix compile --warnings-as-errors` → clean.

- [ ] **Step 6: Commit**

```bash
git add backend/lib/legend/core/library.ex backend/lib/legend/core/agents/session_server.ex backend/test/legend/core/library_test.exs
git commit -m "feat(library): mode-aware primer (:path filesystem vs :api MCP tools)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Test tunnel double + Test runtime tunnel capability

**Files:**
- Create: `backend/test/support/tunnels/test.ex`
- Modify: `backend/config/test.exs`

- [ ] **Step 1: Create `Legend.Tunnels.Test`** at `backend/test/support/tunnels/test.ex`

```elixir
defmodule Legend.Tunnels.Test do
  @moduledoc "In-memory tunnel double for tests. Records open/close to the listener pid."
  @behaviour Legend.Core.Tunnel

  @impl true
  def id, do: "test_tunnel"

  @impl true
  def open(target) do
    notify({:test_tunnel, :open, target})
    {:ok, %{base_url: "http://127.0.0.1:9999", handle: %{target: target}}}
  end

  @impl true
  def close(handle) do
    notify({:test_tunnel, :close, handle})
    :ok
  end

  defp notify(msg) do
    case Application.get_env(:legend, :test_runtime_listener) do
      nil -> :ok
      pid -> send(pid, msg)
    end
  end
end
```
(Reuses the same `:test_runtime_listener` pid the Test runtime uses, so a test that `TestRuntime.subscribe()`s also receives tunnel events.)

- [ ] **Step 2: Register it in test config** — `backend/config/test.exs`

Add (near the runtimes registration `config :legend, :runtimes, …`):
```elixir
config :legend, :tunnels, [Legend.Tunnels.Test]
```

- [ ] **Step 3: Compile the test env**

Run: `cd backend && MIX_ENV=test mix compile` → clean.

- [ ] **Step 4: Commit**

```bash
git add backend/test/support/tunnels/test.ex backend/config/test.exs
git commit -m "test: Legend.Tunnels.Test double + register in test env

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: SessionServer tunnel wiring

**Files:**
- Modify: `backend/lib/legend/core/agents/session_server.ex`
- Test: `backend/test/legend/core/agents/session_tunnel_test.exs`

> The `:api` library mode currently produces empty `build_opts`/`platform_env` (Spec 2a). Now: open the tunnel for `caps.tunnel` runtimes, thread `base_url` in, inject MCP URL + token + `:api` primer, close on stop. The tunnel opens in `init` before `build_command`, so resume re-opens automatically (init runs on every (re)start).

- [ ] **Step 1: Write the failing test** at `backend/test/legend/core/agents/session_tunnel_test.exs`

```elixir
defmodule Legend.Core.Agents.SessionTunnelTest do
  use Legend.DataCase

  alias Legend.Core.Agents
  alias Legend.Runtimes.Test, as: TestRuntime

  setup do
    TestRuntime.subscribe()

    on_exit(fn ->
      Application.delete_env(:legend, :test_runtime_capabilities)

      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
      end
    end)

    :ok
  end

  test "an :api runtime with a tunnel opens it and wires the agent to the loopback MCP url" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})

    {:ok, _} = Agents.start_session(%{name: "t", harness_id: "claude_code", runtime_id: "test"})

    assert_receive {:test_tunnel, :open, %{session_id: _}}, 1000
    assert_receive {:test_runtime, :start, spec, _opts}, 1000

    # MCP URL points at the tunnel loopback, not the local endpoint.
    assert spec.env["LEGEND_MCP_URL"] == "http://127.0.0.1:9999/api/mcp"
    assert is_binary(spec.env["LEGEND_SESSION_TOKEN"])
    refute Map.has_key?(spec.env, "LEGEND_LIBRARY")
  end

  test "destroying the session closes the tunnel" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})
    {:ok, s} = Agents.start_session(%{name: "t2", harness_id: "claude_code", runtime_id: "test"})
    assert_receive {:test_tunnel, :open, _}, 1000

    :ok = Agents.destroy_session(Agents.get_session!(s.id))
    assert_receive {:test_tunnel, :close, _}, 1000
  end

  test "a :path runtime opens no tunnel and keeps the endpoint MCP url" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :path, tunnel: nil})
    {:ok, _} = Agents.start_session(%{name: "p", harness_id: "claude_code", runtime_id: "test"})

    assert_receive {:test_runtime, :start, spec, _opts}, 1000
    refute_received {:test_tunnel, :open, _}
    assert Map.has_key?(spec.env, "LEGEND_LIBRARY")
  end
end
```

- [ ] **Step 2: Run, verify it fails**

Run: `cd backend && mix test test/legend/core/agents/session_tunnel_test.exs` → FAIL (no tunnel opened; `:api` env empty).

- [ ] **Step 3: Wire the tunnel into `init/1`** — `backend/lib/legend/core/agents/session_server.ex`

Change the `with` to open the tunnel and thread `base_url`:
```elixir
    with {:ok, harness} <- fetch_registered(Legend.Core.Harness.Registry, session.harness_id),
         {:ok, runtime} <- fetch_registered(Legend.Core.Runtime.Registry, session.runtime_id),
         caps = Legend.Core.Runtime.capabilities(runtime),
         :ok <- maybe_provision(session, harness, runtime, caps),
         {:ok, tunnel, base_url} <- maybe_open_tunnel(session, caps),
         spec = harness.build_command(build_opts(session, mode, caps, base_url)),
         spec = %{spec | env: Map.merge(spec.env, platform_env(session, caps, base_url))},
         {:ok, handle, ref} <- start_or_attach(runtime, spec, session, mode) do
      try do
        session = Agents.mark_session_running!(session, %{runtime_ref: ref})
```
In the success-body state map, add `tunnel: tunnel` (alongside `runtime`/`handle`). In the `rescue` branch, after `runtime.stop(handle)`, add `maybe_close_tunnel(tunnel)`.

Add the helpers:
```elixir
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
```

- [ ] **Step 4: Capability+base_url-aware `build_opts/4`** (replace the `build_opts/3` from 2a)

```elixir
  # :api runtimes reach the library + signal bus over the tunnel (base_url loopback).
  defp build_opts(session, mode, %{library: :api}, base_url) do
    %{
      mode: mode,
      session_id: session.id,
      library: %{primer: Legend.Core.Library.primer(:api)},
      messaging: %{
        primer: Signals.messaging_primer(session),
        instructions: session.instructions
      }
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
      mode: mode,
      session_id: session.id
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
```

- [ ] **Step 5: Capability+base_url-aware `platform_env/3`** (replace `platform_env/2`)

```elixir
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
```

- [ ] **Step 6: Close the tunnel on terminate**

The 2a `terminate/2` stops the runtime. Add tunnel close. Replace the non-exited `terminate` clause:
```elixir
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
```
(The destroy path calls `ensure_stopped` → terminates the server → this closes the tunnel; that satisfies the "destroy closes the tunnel" test.)

- [ ] **Step 7: Run, verify it passes**

Run: `cd backend && mix test test/legend/core/agents/session_tunnel_test.exs` → PASS (3 tests).
Then the full agents + provisioning + reattach + teardown suites: `cd backend && mix test test/legend/core/agents/` → green (the `base_url`-nil `:path` path is unchanged behavior; provisioning/reattach tests use `:api` with `tunnel: "sprite_proxy"` — but that tunnel isn't registered in test, so update those tests to use `tunnel: nil` OR `"test_tunnel"`).

> IMPORTANT cross-test fix: the 2a `session_provisioning_test`/`session_reattach_test`/`session_teardown_test` set `tunnel: "sprite_proxy"` in capabilities. With tunnel wiring live, `"sprite_proxy"` is not registered in the test env → `maybe_open_tunnel` returns `{:error, "tunnel not registered"}` → those sessions now fail. Change those tests' `set_capabilities` to `tunnel: nil` (they don't exercise the tunnel) so they keep asserting provisioning/reattach/teardown without opening one. Make this edit as part of this task and re-run them green.

- [ ] **Step 8: Commit**

```bash
git add backend/lib/legend/core/agents/session_server.ex backend/test/legend/core/agents/session_tunnel_test.exs backend/test/legend/core/agents/session_provisioning_test.exs backend/test/legend/core/agents/session_reattach_test.exs backend/test/legend/core/agents/session_teardown_test.exs
git commit -m "feat(session): open the tunnel for :api runtimes and wire MCP/library over it

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: Live acceptance + final verification

**Files:**
- Modify: `docs/ARCHITECTURE.md`

- [ ] **Step 1: Full live acceptance (manual, gated on `SPRITES_TOKEN`)**

With the backend running and the bridge built, in the UI create a **sprites + Claude Code** session, then verify:
- The agent can `read_messages` / `send_message` — send it a message from another session (or the human via `/messages`) and confirm it arrives (nudge) and the agent reaches the bus.
- The agent can `library_write` an artifact and `library_read` it back (and it appears in the `/library` UI).
- Let the sprite go idle (hibernate), then resume the session — the agent still reaches the backend (carrier reconnected / re-opened).
- Delete the session → the tunnel closes and the sprite is gone.

Record what worked (auth path, any quirks) in the spec's notes / commit.

- [ ] **Step 2: Backend verification**

Run: `cd backend && mix precommit` → compile (warnings-as-errors) + format + test, all green.

- [ ] **Step 3: Frontend verification** (unchanged by 2b, but confirm)

Run: `cd frontend && bun run check && bun run build` → clean.

- [ ] **Step 4: Update `docs/ARCHITECTURE.md`**

In the "Extension architecture" → cloud-runtimes line (updated in 2a), change the parenthetical that says Spec 2b wires the data plane to past tense ("built (Spec 2b): the reverse tunnel carries the MCP signal bus + the `library_*` tools into the sandbox"). In the plugin table's Tunnel row, drop "wires library/MCP into `:api` runtimes (Spec 2b)" from "Reserved" since it's now implemented. Add `2026-06-14-sprites-library-messaging-over-tunnel-design.md` to the spec index.

- [ ] **Step 5: Commit**

```bash
git add docs/ARCHITECTURE.md
git commit -m "docs: mark library + messaging over the tunnel built (Spec 2b)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-review notes (for the implementer)

- **Phase 1 is fix-and-verify, not greenfield.** The tunnel code exists from Spec 1; the risk is *live behavior*. Tasks 1–5 build the bridge, fix the two known bugs (HTTP/1.1, REST-exec launch), add backend reconnect, and prove the path with the curl-from-sprite e2e. Do the live steps — that's the whole point of Phase 1.
- **Cross-task type consistency:** the tunnel handle stored in `SessionServer` state is `{tunnel_module, opaque_handle}` (or `nil`); `maybe_close_tunnel/1` matches that. `SpriteProxy.open` takes `%{session_id: name}` (Task 4) and `SessionServer` passes exactly that (Task 10). The mux handle from `SpriteProxy.open` is `%{server: pid}` (Task 4) — `close/1` matches.
- **The 2a tests set `tunnel: "sprite_proxy"`** in Test-runtime capabilities; that tunnel isn't registered in test, so Task 10 Step 7 flips them to `tunnel: nil`. Don't skip that or the agents suite breaks.
- **`base_url` is nil for `:path`** everywhere; the `:path` branches ignore it and behave exactly as before 2b. `:api` without a tunnel (no `caps.tunnel`) would get `base_url: nil` → `put_mcp` drops MCP and `LEGEND_MCP_URL` is absent — acceptable (an `:api` runtime that declares no tunnel simply has no backend access; sprites always declares one).
- **Library tree shape:** confirm `Library.list_tree/0`'s return shape and adjust `format_entry/1` (Task 6 Step 3 note) — the test only requires the serialization contain `"knowledge"`.
- **Live verification gating:** Tasks 3/5/11 need `SPRITES_TOKEN` (in `.env`) and, for 5/11, the backend running locally. They create + delete real sprites; clean up on failure (`Client.delete_sprite/1`).
