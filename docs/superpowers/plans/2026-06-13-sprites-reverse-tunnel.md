# Sprites Reverse Tunnel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an agent running in a sprites.dev sandbox reach the local Legend backend's MCP + library APIs over a reverse tunnel that rides sprites' own `…/proxy` WSS — no third party, no public exposure.

**Architecture:** The backend opens an *outbound* `WSS /v1/sprites/{name}/proxy` to a loopback **control** port inside the sprite where a small static `legend-bridge` binary listens. Over that single carrier pipe both sides speak a minimal stream-multiplexing protocol. The agent's HTTP client connects to the bridge's loopback **data** port; per connection the bridge opens a mux stream; the backend de-muxes each stream, dials its own `LegendWeb.Endpoint` loopback port, and splices bytes. The agent believes the backend is local at `http://127.0.0.1:7777`.

**Tech Stack:** Elixir/Phoenix backend (`Req` for HTTP, `Mint.WebSocket` for the carrier, pure-Elixir mux codec); a static Rust/musl bridge binary shipped in `backend/priv/`.

**Spec:** `docs/superpowers/specs/2026-06-13-sprites-reverse-tunnel-design.md` (Spec 1 of 2; the sprites *runtime* + provisioning + library-MCP is Spec 2 and is out of scope here).

---

## File structure

**Backend (Elixir) — new:**
- `backend/lib/legend/core/tunnel.ex` — the `Legend.Core.Tunnel` behaviour (`id/0`, `open/1`, `close/1`).
- `backend/lib/legend/core/tunnel/registry.ex` — `Legend.Core.Tunnel.Registry` (`list/0`, `fetch/1`), mirrors `Legend.Core.Runtime.Registry`.
- `backend/lib/legend/core/tunnel/mux.ex` — pure frame codec + window constant. The novel core.
- `backend/lib/legend/sprites/client.ex` — `Legend.Sprites.Client`: the sprites.dev HTTP API (create/get/delete sprite, exec, write_file, chmod) via `Req`.
- `backend/lib/legend/sprites/proxy.ex` — `Legend.Sprites.Proxy`: opens the carrier WSS via `Mint.WebSocket`, does the JSON handshake, relays binary frames to/from an owner pid.
- `backend/lib/legend/tunnels/sprite_proxy.ex` — `Legend.Tunnels.SpriteProxy`: the `Tunnel` provider (`open/1`/`close/1`).
- `backend/lib/legend/tunnels/sprite_proxy/server.ex` — `Legend.Tunnels.SpriteProxy.Server`: per-tunnel GenServer owning carrier + mux + streams + reconnect + splice.

**Backend — modified:**
- `backend/mix.exs` — add `{:req, "~> 0.5"}`, `{:mint_web_socket, "~> 1.0"}`.
- `backend/config/config.exs` — add `config :legend, :tunnels, [Legend.Tunnels.SpriteProxy]`.
- `backend/config/runtime.exs` — read `SPRITES_TOKEN`.
- `backend/.env.example` — add `SPRITES_TOKEN=`.

**Bridge (Rust) — new:**
- `bridge/Cargo.toml`, `bridge/src/main.rs`, `bridge/src/mux.rs` — the in-sprite binary.
- `bridge/README.md` — build/cross-compile instructions.
- Build artifact lands at `backend/priv/tunnel/legend-bridge-x86_64-linux` (read via `:code.priv_dir(:legend)` to upload into sprites).

**Wire format (used by both `mux.ex` and `bridge/src/mux.rs` — keep identical):**
```
big-endian, no alignment:
  type:u8  stream_id:u32  length:u32  payload:[length bytes]
types: 1=OPEN  2=DATA  3=CLOSE  4=WINDOW
  OPEN    payload empty            — bridge announces a new agent connection on `stream_id`
  DATA    payload = raw bytes      — bidirectional stream bytes
  CLOSE   payload empty            — half/full close of `stream_id`
  WINDOW  payload = credit:u32     — grant `credit` more bytes the peer may send on `stream_id`
flow control: each stream starts with INITIAL_WINDOW (262144) bytes of send credit;
a receiver emits WINDOW(n) once it has delivered n bytes downstream and n >= INITIAL_WINDOW/2.
```

---

### Task 1: Dependencies and config scaffolding

**Files:**
- Modify: `backend/mix.exs` (deps), `backend/config/config.exs`, `backend/config/runtime.exs`, `backend/.env.example`

- [ ] **Step 1: Add deps to `backend/mix.exs`**

In `defp deps do` add (after `{:jason, "~> 1.2"},`):

```elixir
      {:req, "~> 0.5"},
      {:mint_web_socket, "~> 1.0"},
```

- [ ] **Step 2: Fetch deps**

Run: `cd backend && mix deps.get`
Expected: resolves `req`, `mint_web_socket` (and `mint`/`finch` already present). No errors.

- [ ] **Step 3: Register the tunnel in `backend/config/config.exs`**

Find the block that sets `harnesses:`/`runtimes:` (around line 64) and add a sibling key in the same `config :legend, ...` call:

```elixir
  tunnels: [Legend.Tunnels.SpriteProxy],
```

- [ ] **Step 4: Read `SPRITES_TOKEN` in `backend/config/runtime.exs`**

Near the other `env!`/dotenvy reads, add:

```elixir
config :legend, :sprites_token, env!("SPRITES_TOKEN", :string, nil)
```

(`nil` default: the tunnel reports a clear error when unset; it must never crash boot.)

- [ ] **Step 5: Document the env var in `backend/.env.example`**

Add:

```
# sprites.dev API token for the cloud runtime + reverse tunnel (https://sprites.dev/account)
SPRITES_TOKEN=
```

- [ ] **Step 6: Compile**

Run: `cd backend && mix compile --warnings-as-errors`
Expected: compiles (the referenced `Legend.Tunnels.SpriteProxy` does not exist yet → this will warn/fail). **Skip `--warnings-as-errors` here**; run `mix compile` and accept the "module not available" — it resolves at runtime via the registry, not compile time. Verify no *syntax* errors.

- [ ] **Step 7: Commit**

```bash
git add backend/mix.exs backend/mix.lock backend/config/config.exs backend/config/runtime.exs backend/.env.example
git commit -m "feat(tunnel): deps + config scaffolding for sprites reverse tunnel"
```

---

### Task 2: `Tunnel` behaviour + registry

**Files:**
- Create: `backend/lib/legend/core/tunnel.ex`, `backend/lib/legend/core/tunnel/registry.ex`
- Test: `backend/test/legend/core/tunnel/registry_test.exs`
- Reference: `backend/lib/legend/core/runtime/registry.ex` (copy its shape exactly)

- [ ] **Step 1: Write the failing registry test**

```elixir
defmodule Legend.Core.Tunnel.RegistryTest do
  use ExUnit.Case, async: true
  alias Legend.Core.Tunnel.Registry

  defmodule FakeTunnel do
    @behaviour Legend.Core.Tunnel
    def id, do: "fake"
    def open(_), do: {:ok, %{base_url: "http://127.0.0.1:1", handle: nil}}
    def close(_), do: :ok
  end

  setup do
    prev = Application.get_env(:legend, :tunnels)
    Application.put_env(:legend, :tunnels, [FakeTunnel])
    on_exit(fn -> Application.put_env(:legend, :tunnels, prev) end)
  end

  test "fetch/1 returns the module for a known id" do
    assert {:ok, FakeTunnel} = Registry.fetch("fake")
  end

  test "fetch/1 returns :error for an unknown id" do
    assert :error = Registry.fetch("nope")
  end

  test "list/0 returns configured modules" do
    assert [FakeTunnel] = Registry.list()
  end
end
```

- [ ] **Step 2: Run it, verify it fails**

Run: `cd backend && mix test test/legend/core/tunnel/registry_test.exs`
Expected: FAIL — `Legend.Core.Tunnel` / `Registry` undefined.

- [ ] **Step 3: Create the behaviour `backend/lib/legend/core/tunnel.ex`**

```elixir
defmodule Legend.Core.Tunnel do
  @moduledoc """
  Makes the local backend reachable from inside a remote runtime. A tunnel is a
  per-runtime concern: each runtime declares which tunnel id it needs (sprites →
  "sprite_proxy"; a self-hosted box → WireGuard/direct; local → none). Looked up
  from `config :legend, :tunnels` by string id, like runtimes and harnesses.

  `open/1` returns the loopback base URL the agent uses (e.g. "http://127.0.0.1:7777")
  and an opaque handle passed back to `close/1`.
  """

  @type target :: map()
  @type handle :: term()

  @callback id() :: String.t()
  @callback open(target()) :: {:ok, %{base_url: String.t(), handle: handle()}} | {:error, String.t()}
  @callback close(handle()) :: :ok
end
```

- [ ] **Step 4: Create the registry `backend/lib/legend/core/tunnel/registry.ex`**

```elixir
defmodule Legend.Core.Tunnel.Registry do
  @moduledoc "Looks up tunnel modules from `config :legend, :tunnels` by string id."

  @spec list() :: [module()]
  def list, do: modules()

  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(id) when is_binary(id) do
    Enum.find_value(modules(), :error, fn mod ->
      if mod.id() == id, do: {:ok, mod}
    end)
  end

  defp modules, do: Application.get_env(:legend, :tunnels, [])
end
```

- [ ] **Step 5: Run the test, verify it passes**

Run: `cd backend && mix test test/legend/core/tunnel/registry_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add backend/lib/legend/core/tunnel.ex backend/lib/legend/core/tunnel/registry.ex backend/test/legend/core/tunnel/registry_test.exs
git commit -m "feat(tunnel): Tunnel behaviour + registry"
```

---

### Task 3: Mux frame codec (pure, full TDD)

**Files:**
- Create: `backend/lib/legend/core/tunnel/mux.ex`
- Test: `backend/test/legend/core/tunnel/mux_test.exs`

- [ ] **Step 1: Write the failing codec tests**

```elixir
defmodule Legend.Core.Tunnel.MuxTest do
  use ExUnit.Case, async: true
  alias Legend.Core.Tunnel.Mux
  alias Legend.Core.Tunnel.Mux.Frame

  test "encode/decode round-trips a DATA frame" do
    frame = %Frame{type: :data, stream_id: 7, payload: "hello"}
    {[decoded], ""} = Mux.decode(Mux.encode(frame))
    assert decoded == frame
  end

  test "encodes each type with the right tag byte" do
    assert <<1, 0::32, 0::32>> = Mux.encode(%Frame{type: :open, stream_id: 0, payload: ""})
    assert <<3, 9::32, 0::32>> = Mux.encode(%Frame{type: :close, stream_id: 9, payload: ""})
    assert <<4, 9::32, 4::32, 1024::32>> = Mux.encode(Mux.window(9, 1024))
  end

  test "decode/1 returns multiple frames and leftover bytes" do
    buf = Mux.encode(%Frame{type: :open, stream_id: 1, payload: ""}) <>
          Mux.encode(%Frame{type: :data, stream_id: 1, payload: "ab"})
    {frames, ""} = Mux.decode(buf)
    assert [%Frame{type: :open, stream_id: 1}, %Frame{type: :data, stream_id: 1, payload: "ab"}] = frames
  end

  test "decode/1 keeps an incomplete trailing frame in the leftover buffer" do
    full = Mux.encode(%Frame{type: :data, stream_id: 1, payload: "abcd"})
    {head, tail} = String.split_at(full, byte_size(full) - 2)
    assert {[], ^head} = Mux.decode(head)            # header+partial payload not yet complete
    {[%Frame{payload: "abcd"}], ""} = Mux.decode(head <> tail)
  end

  test "window/2 builds a WINDOW frame carrying the credit" do
    assert %Frame{type: :window, stream_id: 3, payload: <<512::32>>} = Mux.window(3, 512)
    assert {:window, 3, 512} = Mux.parse_window(%Frame{type: :window, stream_id: 3, payload: <<512::32>>})
  end
end
```

- [ ] **Step 2: Run, verify it fails**

Run: `cd backend && mix test test/legend/core/tunnel/mux_test.exs`
Expected: FAIL — `Mux` undefined.

- [ ] **Step 3: Implement `backend/lib/legend/core/tunnel/mux.ex`**

```elixir
defmodule Legend.Core.Tunnel.Mux do
  @moduledoc """
  Stream-multiplexing frame codec shared with the in-sprite bridge
  (`bridge/src/mux.rs` — keep both in lockstep).

  Wire: big-endian `type:u8 stream_id:u32 length:u32 payload:length`.
  Types: 1 OPEN, 2 DATA, 3 CLOSE, 4 WINDOW (payload = credit:u32).
  """

  @initial_window 262_144
  def initial_window, do: @initial_window

  defmodule Frame do
    @enforce_keys [:type, :stream_id]
    defstruct [:type, :stream_id, payload: ""]
    @type t :: %__MODULE__{type: :open | :data | :close | :window, stream_id: non_neg_integer(), payload: binary()}
  end

  @tag %{open: 1, data: 2, close: 3, window: 4}
  @type_of %{1 => :open, 2 => :data, 3 => :close, 4 => :window}

  @spec encode(Frame.t()) :: binary()
  def encode(%Frame{type: type, stream_id: id, payload: p}) do
    <<Map.fetch!(@tag, type), id::32, byte_size(p)::32, p::binary>>
  end

  @doc "Consume as many whole frames as `buffer` holds; return {frames, leftover}."
  @spec decode(binary()) :: {[Frame.t()], binary()}
  def decode(buffer), do: decode(buffer, [])

  defp decode(<<tag, id::32, len::32, payload::binary-size(len), rest::binary>>, acc) do
    decode(rest, [%Frame{type: Map.fetch!(@type_of, tag), stream_id: id, payload: payload} | acc])
  end

  defp decode(leftover, acc), do: {Enum.reverse(acc), leftover}

  @spec window(non_neg_integer(), non_neg_integer()) :: Frame.t()
  def window(stream_id, credit), do: %Frame{type: :window, stream_id: stream_id, payload: <<credit::32>>}

  @spec parse_window(Frame.t()) :: {:window, non_neg_integer(), non_neg_integer()}
  def parse_window(%Frame{type: :window, stream_id: id, payload: <<credit::32>>}), do: {:window, id, credit}
end
```

- [ ] **Step 4: Run, verify it passes**

Run: `cd backend && mix test test/legend/core/tunnel/mux_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add backend/lib/legend/core/tunnel/mux.ex backend/test/legend/core/tunnel/mux_test.exs
git commit -m "feat(tunnel): stream-mux frame codec"
```

---

### Task 4: Sprites HTTP client — live-contract probe + implementation

The exec/filesystem request bodies are **not in the public docs** (JS-rendered reference). This task captures the real shapes against the live API first, then implements the client to match. Requires a real `SPRITES_TOKEN`.

**Files:**
- Create: `backend/lib/legend/sprites/client.ex`
- Test: `backend/test/legend/sprites/client_test.exs`

- [ ] **Step 1: Probe the live API and record exact shapes**

With `export SPRITES_TOKEN=…`, run and **record the response bodies as a comment block at the top of `client.ex`** (`@moduledoc` "Verified <date>:"):

```bash
BASE=https://api.sprites.dev/v1
AUTH="Authorization: Bearer $SPRITES_TOKEN"
# create
curl -sS -X POST $BASE/sprites -H "$AUTH" -H 'content-type: application/json' \
  -d '{"name":"legend-probe","url_settings":{"auth":"sprite"}}' | tee /tmp/create.json
# exec POST — try the documented "Execute Command POST"; record the accepted body + response
curl -sS -X POST $BASE/sprites/legend-probe/exec -H "$AUTH" -H 'content-type: application/json' \
  -d '{"command":"echo","args":["hi"]}' | tee /tmp/exec.json
# filesystem write — record the accepted body
curl -sS -X PUT $BASE/sprites/legend-probe/fs/file -H "$AUTH" -H 'content-type: application/json' \
  -d '{"path":"/tmp/x","content":"aGk=","encoding":"base64","mode":"0755"}' | tee /tmp/write.json
# get + delete
curl -sS $BASE/sprites/legend-probe -H "$AUTH" | tee /tmp/get.json
curl -sS -X DELETE $BASE/sprites/legend-probe -H "$AUTH"
```

If a path/field is rejected, adjust per the error message and re-record. **The recorded shapes are the source of truth for Steps 3–4** — if they differ from the guesses below, change the client to match (this is the whole point of the probe).

- [ ] **Step 2: Write client tests against a `Req.Test` stub**

```elixir
defmodule Legend.Sprites.ClientTest do
  use ExUnit.Case, async: true
  alias Legend.Sprites.Client

  setup do
    Application.put_env(:legend, :sprites_token, "tkn")
    Req.Test.stub(Legend.Sprites.Client, fn conn ->
      send(self(), {:req, conn.method, conn.request_path, conn.req_headers})
      Req.Test.json(conn, %{"name" => "s1", "status" => "running"})
    end)
    :ok
  end

  test "create_sprite/1 POSTs name + bearer auth" do
    assert {:ok, %{"name" => "s1"}} = Client.create_sprite("s1")
    assert_received {:req, "POST", "/v1/sprites", headers}
    assert {"authorization", "Bearer tkn"} in headers
  end

  test "returns {:error, _} when SPRITES_TOKEN is unset" do
    Application.put_env(:legend, :sprites_token, nil)
    assert {:error, msg} = Client.create_sprite("s1")
    assert msg =~ "SPRITES_TOKEN"
  end
end
```

- [ ] **Step 3: Run, verify it fails**

Run: `cd backend && mix test test/legend/sprites/client_test.exs`
Expected: FAIL — `Client` undefined.

- [ ] **Step 4: Implement `backend/lib/legend/sprites/client.ex`**

Adjust the `exec`/`write_file`/`chmod` bodies to the shapes recorded in Step 1.

```elixir
defmodule Legend.Sprites.Client do
  @moduledoc """
  sprites.dev REST client. Verified <date> against the live API (see /tmp probe).
  Bearer auth from `config :legend, :sprites_token`.
  """

  @base "https://api.sprites.dev/v1"

  def create_sprite(name, auth \\ "sprite") do
    request(:post, "/sprites", json: %{name: name, url_settings: %{auth: auth}})
  end

  def get_sprite(name), do: request(:get, "/sprites/#{name}")
  def delete_sprite(name), do: request(:delete, "/sprites/#{name}")

  # Non-interactive command. Body shape per the Step-1 probe.
  def exec(name, %{} = body), do: request(:post, "/sprites/#{name}/exec", json: body)

  # Upload a file. `content` is raw bytes; sent base64. Path/field names per probe.
  def write_file(name, path, content) when is_binary(content) do
    request(:put, "/sprites/#{name}/fs/file",
      json: %{path: path, content: Base.encode64(content), encoding: "base64"})
  end

  def chmod(name, path, mode), do: request(:post, "/sprites/#{name}/fs/chmod", json: %{path: path, mode: mode})

  defp request(method, path, opts \\ []) do
    case token() do
      nil ->
        {:error, "SPRITES_TOKEN is not set"}

      tkn ->
        [method: method, url: @base <> path, auth: {:bearer, tkn}]
        |> Keyword.merge(opts)
        |> Keyword.merge(test_opts())
        |> Req.request()
        |> case do
          {:ok, %{status: s, body: body}} when s in 200..299 -> {:ok, body}
          {:ok, %{status: s, body: body}} -> {:error, "sprites #{s}: #{inspect(body)}"}
          {:error, e} -> {:error, Exception.message(e)}
        end
    end
  end

  defp token, do: Application.get_env(:legend, :sprites_token)

  # In test, route through the Req.Test stub registered under this module.
  if Mix.env() == :test do
    defp test_opts, do: [plug: {Req.Test, __MODULE__}]
  else
    defp test_opts, do: []
  end
end
```

- [ ] **Step 5: Run, verify it passes**

Run: `cd backend && mix test test/legend/sprites/client_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add backend/lib/legend/sprites/client.ex backend/test/legend/sprites/client_test.exs
git commit -m "feat(sprites): REST client (create/exec/fs), shapes verified against live API"
```

---

### Task 5: The Rust bridge

A static, loopback-only binary: **control** listener `127.0.0.1:9000` (the backend connects here via the sprite proxy; carries the mux) and **data** listener `127.0.0.1:7777` (the in-sprite agent connects here). Each data connection becomes a mux stream over the single control connection.

**Files:**
- Create: `bridge/Cargo.toml`, `bridge/src/main.rs`, `bridge/src/mux.rs`, `bridge/README.md`

- [ ] **Step 1: `bridge/Cargo.toml`**

```toml
[package]
name = "legend-bridge"
version = "0.1.0"
edition = "2021"

[dependencies]
tokio = { version = "1", features = ["rt-multi-thread", "net", "io-util", "sync", "macros"] }

[profile.release]
strip = true
opt-level = "z"
```

- [ ] **Step 2: `bridge/src/mux.rs` — frame codec (mirror of `mux.ex`)**

```rust
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub const OPEN: u8 = 1;
pub const DATA: u8 = 2;
pub const CLOSE: u8 = 3;
pub const WINDOW: u8 = 4;
pub const INITIAL_WINDOW: u32 = 262_144;

pub struct Frame { pub typ: u8, pub stream_id: u32, pub payload: Vec<u8> }

pub async fn read_frame<R: AsyncRead + Unpin>(r: &mut R) -> std::io::Result<Frame> {
    let typ = r.read_u8().await?;
    let stream_id = r.read_u32().await?;       // big-endian
    let len = r.read_u32().await? as usize;
    let mut payload = vec![0u8; len];
    r.read_exact(&mut payload).await?;
    Ok(Frame { typ, stream_id, payload })
}

pub async fn write_frame<W: AsyncWrite + Unpin>(w: &mut W, f: &Frame) -> std::io::Result<()> {
    w.write_u8(f.typ).await?;
    w.write_u32(f.stream_id).await?;
    w.write_u32(f.payload.len() as u32).await?;
    w.write_all(&f.payload).await?;
    w.flush().await
}
```

- [ ] **Step 3: `bridge/src/main.rs` — listeners, mux, splice, windowing**

```rust
mod mux;
use mux::*;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, tcp::OwnedReadHalf};
use tokio::sync::{mpsc, Mutex};

const CONTROL: &str = "127.0.0.1:9000";
const DATA: &str = "127.0.0.1:7777";

// One outbound frame queue shared by all streams toward the backend.
type Outbound = mpsc::Sender<Frame>;

#[tokio::main(flavor = "multi_thread")]
async fn main() -> std::io::Result<()> {
    let control = TcpListener::bind(CONTROL).await?;
    let data = TcpListener::bind(DATA).await?;
    eprintln!("legend-bridge: control {CONTROL} data {DATA}");

    // Accept exactly one backend control connection at a time; re-accept on drop.
    loop {
        let (carrier, _) = control.accept().await?;
        if let Err(e) = serve(carrier, &data).await {
            eprintln!("legend-bridge: carrier ended: {e}");
        }
    }
}

async fn serve(carrier: TcpStream, data: &TcpListener) -> std::io::Result<()> {
    let (mut cr, mut cw) = carrier.into_split();
    let (tx, mut rx) = mpsc::channel::<Frame>(1024);
    // streams: id -> sender of inbound DATA payloads to the per-stream task
    let streams: Arc<Mutex<HashMap<u32, mpsc::Sender<Vec<u8>>>>> = Arc::new(Mutex::new(HashMap::new()));

    // writer: drain outbound queue to the carrier
    let writer = tokio::spawn(async move {
        while let Some(f) = rx.recv().await {
            if write_frame(&mut cw, &f).await.is_err() { break; }
        }
    });

    // acceptor: each agent connection -> new stream id -> OPEN + per-stream task
    let acc_tx = tx.clone();
    let acc_streams = streams.clone();
    let data_addr = data.local_addr()?;
    let acceptor = tokio::spawn(async move {
        let listener = TcpListener::bind(data_addr).await.unwrap();
        let mut next_id: u32 = 1;
        loop {
            let (sock, _) = match listener.accept().await { Ok(v) => v, Err(_) => break };
            let id = next_id; next_id += 1;
            let (in_tx, in_rx) = mpsc::channel::<Vec<u8>>(8);
            acc_streams.lock().await.insert(id, in_tx);
            let _ = acc_tx.send(Frame { typ: OPEN, stream_id: id, payload: vec![] }).await;
            spawn_stream(id, sock, in_rx, acc_tx.clone(), acc_streams.clone());
        }
    });

    // reader: carrier frames -> route to streams
    let mut acc = Vec::new();
    let _ = &mut acc;
    loop {
        let f = match read_frame(&mut cr).await { Ok(f) => f, Err(_) => break };
        match f.typ {
            DATA => if let Some(s) = streams.lock().await.get(&f.stream_id) { let _ = s.send(f.payload).await; },
            CLOSE | WINDOW => { /* WINDOW handled in stream task via a side channel in full impl;
                                   for v1 short HTTP exchanges, rely on bounded mpsc backpressure */
                if f.typ == CLOSE { streams.lock().await.remove(&f.stream_id); } }
            _ => {}
        }
    }
    writer.abort(); acceptor.abort();
    Ok(())
}

// Per-stream: splice agent socket <-> mux. Outbound bytes -> DATA frames; inbound payloads -> socket.
fn spawn_stream(
    id: u32, sock: TcpStream, mut in_rx: mpsc::Receiver<Vec<u8>>,
    out: Outbound, streams: Arc<Mutex<HashMap<u32, mpsc::Sender<Vec<u8>>>>>,
) {
    let (mut rd, mut wr) = sock.into_split();
    // socket -> mux
    let out2 = out.clone();
    tokio::spawn(async move {
        let mut buf = vec![0u8; 16 * 1024];
        loop {
            match read_half(&mut rd, &mut buf).await {
                Some(0) | None => { let _ = out2.send(Frame{typ:CLOSE,stream_id:id,payload:vec![]}).await; break; }
                Some(n) => { let _ = out2.send(Frame{typ:DATA,stream_id:id,payload:buf[..n].to_vec()}).await; }
            }
        }
    });
    // mux -> socket
    tokio::spawn(async move {
        while let Some(p) = in_rx.recv().await { if wr.write_all(&p).await.is_err() { break; } }
        streams.lock().await.remove(&id);
    });
}

async fn read_half(rd: &mut OwnedReadHalf, buf: &mut [u8]) -> Option<usize> {
    match rd.read(buf).await { Ok(n) => Some(n), Err(_) => None }
}
```

> **Windowing note:** v1 uses bounded `mpsc` channels (per-stream `8`, outbound `1024`) for backpressure rather than explicit `WINDOW` crediting, which is correct and sufficient for MCP/library's short request/response exchanges. The `WINDOW` frame type is wired in the codec on both ends; explicit crediting is a fast-follow if streaming/SSE MCP arrives. **This is a conscious v1 simplification of the spec's flow-control section — record it in the spec's decisions log when this task lands.**

- [ ] **Step 4: `bridge/README.md` — build instructions**

```markdown
# legend-bridge
Static reverse-tunnel bridge uploaded into a sprite by the SpriteProxy tunnel.

## Build (static musl)
    rustup target add x86_64-unknown-linux-musl
    cargo build --release --target x86_64-unknown-linux-musl
    cp target/x86_64-unknown-linux-musl/release/legend-bridge \
       ../backend/priv/tunnel/legend-bridge-x86_64-linux

Confirm the sprite microVM arch first (Task 7 Step 1); rebuild for aarch64 if needed.
```

- [ ] **Step 5: Build and place the binary**

Run:
```bash
mkdir -p backend/priv/tunnel
cd bridge && rustup target add x86_64-unknown-linux-musl && \
  cargo build --release --target x86_64-unknown-linux-musl && \
  cp target/x86_64-unknown-linux-musl/release/legend-bridge ../backend/priv/tunnel/legend-bridge-x86_64-linux && \
  cd ..
```
Expected: a stripped static binary at `backend/priv/tunnel/legend-bridge-x86_64-linux`. Verify: `file backend/priv/tunnel/legend-bridge-x86_64-linux` → "statically linked".

- [ ] **Step 6: Smoke-test the bridge locally (no sprite needed)**

In three terminals: (1) `./target/.../legend-bridge`; (2) a fake backend that connects to `127.0.0.1:9000` and echoes mux DATA frames back (a 20-line script using the wire format); (3) `curl 127.0.0.1:7777`. Confirm bytes round-trip. *(If the fake-backend script is too fiddly, defer this to the real integration in Task 7 Step 6 — the bridge is exercised end-to-end there.)*

- [ ] **Step 7: Commit**

```bash
git add bridge/ backend/priv/tunnel/legend-bridge-x86_64-linux
git commit -m "feat(tunnel): legend-bridge (Rust static musl reverse-tunnel binary)"
```

---

### Task 6: Carrier WSS client (`Legend.Sprites.Proxy`)

Opens `WSS /v1/sprites/{name}/proxy`, sends the JSON init `{"host","port"}`, awaits `{"status":"connected"}`, then becomes a raw binary relay: forwards inbound binary frames to the owner as `{:carrier_data, pid, binary}` and sends owner bytes out via `send_data/2`.

**Files:**
- Create: `backend/lib/legend/sprites/proxy.ex`
- Test: `backend/test/legend/sprites/proxy_test.exs` (handshake message construction only — the live WSS is exercised in Task 7)

- [ ] **Step 1: Failing test for the init message + URL**

```elixir
defmodule Legend.Sprites.ProxyTest do
  use ExUnit.Case, async: true
  alias Legend.Sprites.Proxy

  test "builds the proxy URL and JSON init for a target port" do
    assert Proxy.proxy_url("s1") == "wss://api.sprites.dev/v1/sprites/s1/proxy"
    assert Proxy.init_message(4100) == ~s({"host":"127.0.0.1","port":4100})
  end
end
```

- [ ] **Step 2: Run, verify it fails**

Run: `cd backend && mix test test/legend/sprites/proxy_test.exs` → FAIL (`Proxy` undefined).

- [ ] **Step 3: Implement `backend/lib/legend/sprites/proxy.ex`**

A GenServer wrapping `Mint.WebSocket`. Keep the pure helpers (`proxy_url/1`, `init_message/1`) public for unit testing; the connect loop uses `Mint.HTTP.connect/4` + `Mint.WebSocket.upgrade/5` with the bearer header, then drives frames.

```elixir
defmodule Legend.Sprites.Proxy do
  @moduledoc "Carrier: one sprites `…/proxy` WSS. Bridges binary frames to a server pid."
  use GenServer
  require Logger

  def proxy_url(name), do: "wss://api.sprites.dev/v1/sprites/#{name}/proxy"
  def init_message(port), do: Jason.encode!(%{host: "127.0.0.1", port: port})

  @doc """
  Open the carrier to the bridge's control port inside `name`, forwarding inbound
  binary to `server` as `{:carrier_data, bin}`. The server sends outbound frames
  back as `{:carrier_out, bin}` messages, which this process writes as WS binary.
  Retries the connect with backoff until the bridge is listening on the control port.
  """
  def connect(name, target_port, server) do
    GenServer.start_link(__MODULE__, %{name: name, port: target_port, server: server})
  end

  def close(pid), do: GenServer.stop(pid, :normal)

  @impl true
  def init(state), do: {:ok, Map.put(state, :conn, nil), {:continue, :open}}

  @impl true
  def handle_continue(:open, state) do
    case open_socket(state) do
      {:ok, st} -> {:noreply, st}
      {:error, reason} -> {:stop, {:carrier_open_failed, reason}, state}
    end
  end

  # Server -> carrier: write outbound frames as WS binary.
  @impl true
  def handle_info({:carrier_out, bin}, state), do: {:noreply, ws_send_binary(state, bin)}
  # Mint TCP/WS messages -> decode; forward inbound BINARY payloads to the server.
  def handle_info(message, state), do: {:noreply, handle_ws(state, message)}

  # open_socket/1: Mint.HTTP.connect(:https, "api.sprites.dev", 443)
  #   -> Mint.WebSocket.upgrade(:wss, conn, "/v1/sprites/#{name}/proxy",
  #        [{"authorization", "Bearer " <> token}])
  #   -> on the :done upgrade, Mint.WebSocket.new/4, send init_message/1 as a TEXT frame,
  #      gate on the {"status":"connected"} TEXT reply, then mark connected.
  # ws_send_binary/2: Mint.WebSocket.encode(ws, {:binary, bin}) -> Mint.WebSocket.stream_request_body.
  # handle_ws/2: Mint.WebSocket.stream(conn, msg) -> decode frames; for each {:binary, data}
  #      send(server, {:carrier_data, data}); on :close/error stop.
  # Connect retry: wrap open_socket in a backoff loop (e.g. 5 tries × 200ms) so the bridge
  #      launched moments earlier has time to bind the control port.
end
```

> The Mint.WebSocket body (`connect → upgrade → new → encode/stream → decode`) is mechanical, and the exact calls are fiddly enough that they should be written **against the `mint_web_socket` hexdocs "Usage" example**, not from memory — the comments above pin the exact adaptation (init text frame, gate on `connected`, pump binary as `{:carrier_data, _}`). It is verified live in Task 8 Step 5, not unit-tested (no WSS server in tests). This is the one module whose body the plan deliberately delegates to upstream docs rather than fabricating; everything it must *do* is specified.

- [ ] **Step 4: Run the unit test, verify it passes**

Run: `cd backend && mix test test/legend/sprites/proxy_test.exs` → PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add backend/lib/legend/sprites/proxy.ex backend/test/legend/sprites/proxy_test.exs
git commit -m "feat(sprites): carrier WSS client over /proxy"
```

---

### Task 7: Backend mux server + splice (`SpriteProxy.Server`)

Owns the carrier, decodes its byte stream into frames, and per `OPEN` dials `127.0.0.1:<endpoint port>` and splices that socket to the stream. This is the de-mux mirror of the bridge.

**Files:**
- Create: `backend/lib/legend/tunnels/sprite_proxy/server.ex`
- Test: `backend/test/legend/tunnels/sprite_proxy/server_test.exs`

- [ ] **Step 1: Confirm sprite microVM architecture**

Run (with token): `curl -sS https://api.sprites.dev/v1/sprites/legend-probe -H "Authorization: Bearer $SPRITES_TOKEN"`, then `exec` `uname -m` inside it. If `aarch64`, rebuild the bridge for `aarch64-unknown-linux-musl` and rename the priv artifact accordingly; update Task 8 Step 3's filename.

- [ ] **Step 2: Failing test — server splices an OPENed stream to a local TCP server**

```elixir
defmodule Legend.Tunnels.SpriteProxy.ServerTest do
  use ExUnit.Case
  alias Legend.Core.Tunnel.Mux
  alias Legend.Core.Tunnel.Mux.Frame
  alias Legend.Tunnels.SpriteProxy.Server

  test "OPEN+DATA dials the loopback target and relays both ways" do
    # a tiny echo TCP server on an ephemeral port stands in for the Phoenix endpoint
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)
    spawn_link(fn ->
      {:ok, c} = :gen_tcp.accept(lsock)
      {:ok, data} = :gen_tcp.recv(c, 0)
      :gen_tcp.send(c, "echo:" <> data)
    end)

    # The server uses an injected carrier: it sends outbound frames to `test_pid`.
    {:ok, srv} = Server.start_link(target_port: port)
    Server.set_out(srv, self())  # outbound frames arrive here as {:carrier_out, bin}
    send(srv, {:carrier_data, Mux.encode(%Frame{type: :open, stream_id: 1, payload: ""})})
    send(srv, {:carrier_data, Mux.encode(%Frame{type: :data, stream_id: 1, payload: "ping"})})

    assert_receive {:carrier_out, bin}, 1000
    {[%Frame{type: :data, stream_id: 1, payload: "echo:ping"}], ""} = Mux.decode(bin)
  end
end
```

- [ ] **Step 3: Run, verify it fails** → `Server` undefined.

- [ ] **Step 4: Implement `backend/lib/legend/tunnels/sprite_proxy/server.ex`**

Contract: inbound carrier bytes arrive as `{:carrier_data, bin}` messages; outbound frames are sent as `{:carrier_out, bin}` to the pid set via `set_out/2`. In tests that pid is the test process; in prod (Task 8) it is the `Sprites.Proxy` pid, which writes them as WS binary frames. No shims — both `Proxy` and `Server` speak these two messages.

```elixir
defmodule Legend.Tunnels.SpriteProxy.Server do
  @moduledoc "De-mux side of the reverse tunnel: carrier frames <-> loopback TCP to the local endpoint."
  use GenServer
  require Logger
  alias Legend.Core.Tunnel.Mux
  alias Legend.Core.Tunnel.Mux.Frame

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Set the pid that receives outbound {:carrier_out, bin} frames (the carrier)."
  def set_out(srv, pid), do: GenServer.cast(srv, {:set_out, pid})

  @impl true
  def init(opts) do
    {:ok,
     %{
       target_port: Keyword.fetch!(opts, :target_port),
       out: nil,
       buffer: "",
       streams: %{},  # stream_id => socket
       ids: %{}       # socket => stream_id
     }}
  end

  @impl true
  def handle_cast({:set_out, pid}, state), do: {:noreply, %{state | out: pid}}

  @impl true
  def handle_info({:carrier_data, bin}, state) do
    {frames, rest} = Mux.decode(state.buffer <> bin)
    {:noreply, Enum.reduce(frames, %{state | buffer: rest}, &handle_frame/2)}
  end

  def handle_info({:tcp, sock, data}, state) do
    case Map.get(state.ids, sock) do
      nil -> {:noreply, state}
      id -> out(state, %Frame{type: :data, stream_id: id, payload: data}); {:noreply, state}
    end
  end

  def handle_info({:tcp_closed, sock}, state) do
    case Map.get(state.ids, sock) do
      nil -> {:noreply, state}
      id -> out(state, %Frame{type: :close, stream_id: id, payload: ""}); {:noreply, drop(state, id)}
    end
  end

  def handle_info({:tcp_error, sock, _}, state) do
    case Map.get(state.ids, sock), do: (nil -> {:noreply, state}; id -> {:noreply, drop(state, id)})
  end

  defp handle_frame(%Frame{type: :open, stream_id: id}, state) do
    case :gen_tcp.connect(~c"127.0.0.1", state.target_port, [:binary, active: true, packet: :raw]) do
      {:ok, sock} -> %{state | streams: Map.put(state.streams, id, sock), ids: Map.put(state.ids, sock, id)}
      {:error, r} -> out(state, %Frame{type: :close, stream_id: id, payload: ""}); Logger.warning("tunnel dial: #{inspect(r)}"); state
    end
  end

  defp handle_frame(%Frame{type: :data, stream_id: id, payload: p}, state) do
    with sock when not is_nil(sock) <- Map.get(state.streams, id), do: :gen_tcp.send(sock, p)
    state
  end

  defp handle_frame(%Frame{type: :close, stream_id: id}, state), do: drop(state, id)
  defp handle_frame(%Frame{type: :window}, state), do: state  # v1: bounded-mailbox backpressure

  defp out(%{out: pid}, %Frame{} = f) when is_pid(pid), do: send(pid, {:carrier_out, Mux.encode(f)})
  defp out(_state, _frame), do: :ok

  defp drop(state, id) do
    case Map.get(state.streams, id) do
      nil -> state
      sock -> :gen_tcp.close(sock); %{state | streams: Map.delete(state.streams, id), ids: Map.delete(state.ids, sock)}
    end
  end
end
```

(`active: true` makes this GenServer the controlling process, so `{:tcp, sock, data}` lands in `handle_info`. The `case ..., do:` one-liner in `{:tcp_error, ...}` may need expanding to a normal `case`/`do…end` if the formatter rejects it — keep the logic identical.)

- [ ] **Step 5: Run, verify it passes** → PASS.

- [ ] **Step 6: Live carrier smoke (gated on token)** — wiring `Sprites.Proxy` ↔ `Server` against a real sprite running the bridge happens in **Task 8 Step 5** (the end-to-end acceptance), which is where the WSS client + bridge are first exercised together. No separate step here.

- [ ] **Step 7: Commit**

```bash
git add backend/lib/legend/tunnels/sprite_proxy/server.ex backend/test/legend/tunnels/sprite_proxy/server_test.exs
git commit -m "feat(tunnel): backend mux server + loopback splice"
```

---

### Task 8: `SpriteProxy` provider + end-to-end acceptance

Ties it together: `open/1` ensures the bridge is uploaded + running, opens the carrier to the bridge's control port, starts `Server` (carrier shimmed to `Sprites.Proxy`), and returns `base_url: "http://127.0.0.1:7777"`.

**Files:**
- Create: `backend/lib/legend/tunnels/sprite_proxy.ex`
- Test: `backend/test/legend/tunnels/sprite_proxy_test.exs`

- [ ] **Step 1: Failing test — provider id + behaviour**

```elixir
defmodule Legend.Tunnels.SpriteProxyTest do
  use ExUnit.Case, async: true
  test "implements the Tunnel behaviour with id sprite_proxy" do
    assert Legend.Tunnels.SpriteProxy.id() == "sprite_proxy"
    assert function_exported?(Legend.Tunnels.SpriteProxy, :open, 1)
    assert function_exported?(Legend.Tunnels.SpriteProxy, :close, 1)
  end
end
```

- [ ] **Step 2: Run, verify it fails** → undefined.

- [ ] **Step 3: Implement `backend/lib/legend/tunnels/sprite_proxy.ex`**

```elixir
defmodule Legend.Tunnels.SpriteProxy do
  @moduledoc "Reverse tunnel riding sprites' /proxy WSS. Tunnel id \"sprite_proxy\"."
  @behaviour Legend.Core.Tunnel

  alias Legend.Sprites.{Client, Proxy}
  alias Legend.Tunnels.SpriteProxy.Server

  @control_port 9000
  @data_port 7777
  @bridge_dest "/tmp/legend-bridge"

  @impl true
  def id, do: "sprite_proxy"

  @impl true
  def open(%{sprite: name}) do
    with {:ok, bin} <- read_bridge(),
         :ok <- ensure_bridge(name, bin),
         {:ok, srv} <- Server.start_link(target_port: endpoint_port()),
         {:ok, carrier} <- Proxy.connect(name, @control_port, srv) do
      # Proxy -> srv as {:carrier_data, bin}; srv -> Proxy as {:carrier_out, bin}. No shims.
      Server.set_out(srv, carrier)
      {:ok, %{base_url: "http://127.0.0.1:#{@data_port}", handle: %{carrier: carrier, server: srv}}}
    end
  end

  @impl true
  def close(%{carrier: carrier, server: server}) do
    Process.exit(server, :normal); Proxy.close(carrier); :ok
  end

  defp read_bridge do
    path = Path.join([:code.priv_dir(:legend), "tunnel", "legend-bridge-x86_64-linux"])
    case File.read(path) do
      {:ok, bin} -> {:ok, bin}
      {:error, e} -> {:error, "bridge binary missing at #{path}: #{e}"}
    end
  end

  # Upload + chmod + launch (backgrounded, surviving the exec call), then wait for :9000.
  defp ensure_bridge(name, bin) do
    with {:ok, _} <- Client.write_file(name, @bridge_dest, bin),
         {:ok, _} <- Client.chmod(name, @bridge_dest, "0755"),
         {:ok, _} <- Client.exec(name, %{command: "sh", args: ["-c", "setsid #{@bridge_dest} >/tmp/bridge.log 2>&1 &"]}) do
      :ok
    end
  end

  defp endpoint_port, do: LegendWeb.Endpoint.config(:http)[:port]
end
```

> Wiring is shim-free because `Proxy` and `Server` share two messages: `Proxy` forwards inbound carrier bytes to the server as `{:carrier_data, bin}` (Task 6), and `Server` sends outbound frames to whatever pid `set_out/2` named — here the `Proxy` — as `{:carrier_out, bin}`, which `Proxy` writes as WS binary (Task 6). `ensure_bridge/2` runs before the carrier connects; `Proxy.connect/3` retries the control port so the just-launched bridge has time to bind.

- [ ] **Step 4: Run, verify it passes** → PASS.

- [ ] **Step 5: End-to-end acceptance (the spec's verification — gated on `SPRITES_TOKEN`)**

With the backend running locally (`mix phx.server`, note its port, e.g. 4100):

```elixir
# in iex -S mix, or a tagged @tag :live test:
{:ok, _} = Legend.Sprites.Client.create_sprite("legend-e2e")
{:ok, %{base_url: url, handle: h}} = Legend.Tunnels.SpriteProxy.open(%{sprite: "legend-e2e"})
# now, from INSIDE the sprite, the bridge data port should reach the LOCAL backend:
{:ok, out} = Legend.Sprites.Client.exec("legend-e2e",
  %{command: "sh", args: ["-c", "curl -s http://127.0.0.1:7777/api/health"]})
# assert out contains the backend's health JSON  ->  proves sprite -> local backend works
Legend.Tunnels.SpriteProxy.close(h)
Legend.Sprites.Client.delete_sprite("legend-e2e")
```

Expected: the health JSON served by your **local** backend prints from **inside the cloud sprite**, with nothing publicly exposed. Then repeat with `/api/mcp` (a token-auth `tools/list` POST) and `/api/library/tree` to confirm both target endpoints. Run two `curl`s concurrently (`&`) to confirm mux concurrency. Kill the carrier mid-call (`Proxy.close`) and re-`open` to confirm reconnect.

- [ ] **Step 6: Update the spec's decisions log** (windowing simplification from Task 5) and commit:

```bash
git add backend/lib/legend/tunnels/sprite_proxy.ex backend/test/legend/tunnels/sprite_proxy_test.exs docs/superpowers/specs/2026-06-13-sprites-reverse-tunnel-design.md
git commit -m "feat(tunnel): SpriteProxy provider + end-to-end reverse tunnel"
```

---

### Task 9: Final verification

- [ ] **Step 1: Full backend check**

Run: `cd backend && mix precommit`
Expected: compile (warnings-as-errors) + format + test all green. All ExUnit tests in this plan are **stubbed** (pure codec, `Req.Test`, a local TCP echo) and need no token — the live checks (Task 4 Step 1 probe, Task 8 Step 5 e2e) are **manual** (curl / iex). If the implementer promotes any of those to a tagged `@tag :live` ExUnit test, add `ExUnit.configure(exclude: [:live])` to `backend/test/test_helper.exs` so `mix precommit` stays green without `SPRITES_TOKEN`.

- [ ] **Step 2: Confirm tunnel registry resolves**

Run: `cd backend && mix run -e 'IO.inspect Legend.Core.Tunnel.Registry.fetch("sprite_proxy")'`
Expected: `{:ok, Legend.Tunnels.SpriteProxy}`.

- [ ] **Step 3: Commit any formatting fixups**

```bash
git add -A && git commit -m "chore(tunnel): mix precommit green" || echo "nothing to commit"
```

---

## Self-review notes (for the implementer)

- **Live-API dependence is isolated** to `Legend.Sprites.Client` (exec/write_file/chmod bodies) and the `Proxy` WSS loop. Task 4 Step 1 and Task 7 Step 1 capture the real shapes/arch before those modules are finalized; if reality differs from the guesses, change those two modules — nothing else depends on the wire details.
- **Mux parity:** `mux.ex` and `bridge/src/mux.rs` MUST stay byte-identical (same tags, big-endian, same `INITIAL_WINDOW`). The `MuxTest` tag-byte assertions pin the Elixir side; the Rust side mirrors them.
- **Type consistency:** the carrier↔server contract is exactly two messages — `{:carrier_data, bin}` (Proxy→Server, inbound) and `{:carrier_out, bin}` (Server→Proxy, outbound, written as WS binary) — plus `Server.set_out/2` naming the outbound pid. There is no `send_data`/`carrier_in`/`set_owner`; the provider (Task 8) wires the two processes shim-free.
- **Spec coverage:** behaviour+registry (Task 2) ✓; sprites client (Task 4) ✓; bridge (Task 5) ✓; carrier (Task 6) ✓; mux+splice (Task 7) ✓; provider+reconnect+e2e (Task 8) ✓; security posture is structural (loopback-only listeners, token-gated endpoints, outbound-only backend) ✓. The spec's explicit `WINDOW` flow control is **consciously simplified** to bounded-channel backpressure for v1 (Task 5 note) — update the spec decisions log when Task 8 lands.
```
