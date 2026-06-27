# Relay Phase 3a — Part 2b: Instance Federation Client + "Via Relay" Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Wire the instance to the relay: an outbound `Mint.WebSocket` carrier (`Legend.Federation.RelayClient`) that registers `{handle, secret}` with the relay (Part 2a) and splices each relay-opened stream to the Part-1 `RelayIngressEndpoint`'s loopback port; plus the "via relay" remote-access settings mode + a relay-subdomain pairing QR; plus the boot wiring that starts the ingress + carrier and sets the ingress `check_origin` to the relay subdomain.

**Architecture:** `Legend.Federation.RelayClient` mirrors the proven sprites pattern — `RelayClient.Carrier` (the `Mint.WebSocket` outbound carrier, modeled on `Legend.Sprites.Proxy`: `{:carrier_data, bin}` inbound / `{:carrier_out, bin}` outbound) + `RelayClient.Server` (the splice, modeled on `Legend.Tunnels.SpriteProxy.Server`: decode mux frames, on `OPEN` `:gen_tcp.connect` to the ingress loopback port, `DATA` both ways, `CLOSE`). The relay (not a bridge) opens the streams; the splice target is `RelayIngressEndpoint`'s fixed loopback port. The persisted `remote_access` setting gains a `mode` + relay fields; `Remote.Boot` starts the ingress + carrier and applies relay overrides when `mode == "via_relay"`.

**Tech Stack:** Elixir / Phoenix / Mint.WebSocket (already a dep) / Bandit / SvelteKit (settings UI). The relay app (Part 2a) is the carrier's peer.

## Global Constraints

- Backend: all `mix` from `backend/`; `mix precommit` (compile `--warnings-as-errors` + format + test) green; DB-touching test modules `async: false`.
- Frontend: `bun` from `frontend/`; `bun run check` (0 errors) + `bun run test` green.
- The carrier client speaks the **same mux wire format** as the relay (`Legend.Core.Tunnel.Mux` — big-endian `type:u8 stream_id:u32 length:u32 payload`; `:open=1 :data=2 :close=3 :window=4`). Reuse `Legend.Core.Tunnel.Mux` directly (the instance is in the backend, which owns it).
- The carrier↔server message contract is the existing one: server receives `{:carrier_data, bin}` (mux frames from the relay), and sends `{:carrier_out, bin}` (encoded mux frames) to the carrier. Mirror `SpriteProxy.Server` / `Sprites.Proxy` exactly.
- Trust model unchanged: the carrier registers the instance with the relay (`{handle, secret}`); the **device token is verified by the instance** at the `RelayIngressEndpoint` (`via_relay ⇒ token required`, Part 1). The splice MUST target the `RelayIngressEndpoint` loopback port (NOT the main endpoint) so relayed traffic is `via_relay`-stamped.
- "Via relay" is off by default (the `mode` defaults to `"direct"`); enabling it is loopback-only config (the existing `loopback_only` scope).
- Commit messages end with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## File structure

- Modify `backend/config/config.exs` + `backend/config/runtime.exs` — give `LegendWeb.RelayIngressEndpoint` a fixed loopback `http` port.
- Create `backend/lib/legend/federation/relay_client/server.ex` — the splice server.
- Create `backend/lib/legend/federation/relay_client/carrier.ex` — the `Mint.WebSocket` carrier.
- Create `backend/lib/legend/federation/relay_client.ex` — the provider/supervisor (`start_link`, links carrier+server).
- Modify `backend/lib/legend/core/remote.ex` — `config/0`/`put_config/1` carry `mode` + relay fields; `relay_ingress_enabled?/0` reads the persisted mode.
- Modify `backend/lib/legend/core/remote/boot.ex` — when `mode == "via_relay"`: configure the ingress (`check_origin`) and start the `RelayClient`.
- Modify `backend/lib/legend_web/controllers/remote_controller.ex` — `update/2` accepts relay fields.
- Modify `frontend/src/lib/remote/devices.ts` (`RemoteAccess` type + `setRemoteAccess`), `frontend/src/lib/remote/pairUrl.ts` (relay-subdomain QR), `frontend/src/lib/components/shell/RemoteAccessSection.svelte` (mode selector + relay fields).

---

### Task 1: Give `RelayIngressEndpoint` a fixed loopback http port

**Files:**
- Modify: `backend/config/config.exs` (the `RelayIngressEndpoint` block), `backend/config/runtime.exs` (port from env in prod), `backend/config/test.exs`
- Test: `backend/test/legend_web/relay_ingress_endpoint_test.exs` (assert the configured port)

**Interfaces:**
- Produces: `LegendWeb.RelayIngressEndpoint` configured with `http: [ip: {127,0,0,1}, port: <ingress_port>]` (default `4808`, `RELAY_INGRESS_PORT` override). Consumed by Task 2 (the splice target) + Task 5 boot.

- [ ] **Step 1: Write the failing test.** Add to `relay_ingress_endpoint_test.exs`:

```elixir
  test "ingress is configured for a fixed loopback http port" do
    http = Application.get_env(:legend, LegendWeb.RelayIngressEndpoint)[:http]
    assert http[:ip] == {127, 0, 0, 1}
    assert is_integer(http[:port]) and http[:port] > 0
  end
```

- [ ] **Step 2: Run it — expect FAIL** (no `:http` key yet). `cd backend && mix test test/legend_web/relay_ingress_endpoint_test.exs`

- [ ] **Step 3: Add the fixed port.** In `config/config.exs`'s `RelayIngressEndpoint` block, add `http: [ip: {127, 0, 0, 1}, port: 4808]` (loopback only — relayed traffic arrives here via the carrier splice, never publicly). In `config/runtime.exs`'s `RelayIngressEndpoint` block, override with `RELAY_INGRESS_PORT`: `http: [ip: {127, 0, 0, 1}, port: env!("RELAY_INGRESS_PORT", :integer, 4808)]`. In `config/test.exs`, keep it `server: false` and either omit `http` (ConnTest doesn't need it) or set `port: 0`.

- [ ] **Step 4: Run it — expect PASS.** `mix test test/legend_web/relay_ingress_endpoint_test.exs`
- [ ] **Step 5: `mix precommit`.**
- [ ] **Step 6: Commit** — `feat(relay): fixed loopback http port for the relay ingress endpoint`.

---

### Task 2: `Legend.Federation.RelayClient.Server` — the splice

**Files:**
- Create: `backend/lib/legend/federation/relay_client/server.ex`
- Test: `backend/test/legend/federation/relay_client/server_test.exs`

**Interfaces:**
- Consumes: `Legend.Core.Tunnel.Mux` (+ `Mux.Frame`); the ingress port (Task 1).
- Produces: `Legend.Federation.RelayClient.Server` — a GenServer started with `%{target_port: integer, carrier: pid | nil}`. It receives `{:carrier_data, bin}` (mux frames from the relay), and on `OPEN` `:gen_tcp.connect(~c"127.0.0.1", target_port, [:binary, active: :once, packet: :raw])`, splicing `DATA` both ways and `CLOSE`. It sends `{:carrier_out, Mux.encode(frame)}` to its `carrier`. Mirrors `Legend.Tunnels.SpriteProxy.Server`'s frame handling (read that file).

**Approach:** This is `SpriteProxy.Server` minus the inbound Bandit listener (here the **relay** opens streams toward us; we accept `OPEN` and connect outward to the ingress). Adapt its `handle_info({:carrier_data, bin})` decode loop, `handle_frame(:open|:data|:close)`, `handle_info({:tcp, …})` / `{:tcp_closed, …}`, and the `out/2` helper (`send(carrier, {:carrier_out, Mux.encode(f)})`).

- [ ] **Step 1: Write the failing test.** `server_test.exs` (async: false — it opens loopback TCP). Start a local echo listener on an ephemeral port as the "ingress", point the server at it, set the test process as the `carrier`, feed an `OPEN` then `DATA`, and assert the echoed bytes come back as a `DATA` `{:carrier_out, …}`:

```elixir
defmodule Legend.Federation.RelayClient.ServerTest do
  use ExUnit.Case, async: false
  alias Legend.Core.Tunnel.Mux
  alias Legend.Core.Tunnel.Mux.Frame
  alias Legend.Federation.RelayClient.Server

  setup do
    # echo listener standing in for the RelayIngressEndpoint
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, packet: :raw, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)
    test = self()
    spawn_link(fn ->
      {:ok, s} = :gen_tcp.accept(lsock)
      :inet.setopts(s, active: :once)
      send(test, {:accepted, s})
      echo(s)
    end)
    {:ok, srv} = Server.start_link(%{target_port: port, carrier: self()})
    {:ok, srv: srv}
  end

  defp echo(s) do
    receive do
      {:tcp, ^s, data} -> :gen_tcp.send(s, data); :inet.setopts(s, active: :once); echo(s)
      {:tcp_closed, ^s} -> :ok
    end
  end

  test "OPEN connects to the target; DATA round-trips back as a DATA frame", %{srv: srv} do
    send(srv, {:carrier_data, Mux.encode(%Frame{type: :open, stream_id: 1, payload: ""})})
    assert_receive {:accepted, _s}, 1000
    send(srv, {:carrier_data, Mux.encode(%Frame{type: :data, stream_id: 1, payload: "ping"})})
    assert_receive {:carrier_out, out}, 1000
    assert {:ok, [%Frame{type: :data, stream_id: 1, payload: "ping"}], ""} = Mux.decode(out)
  end
end
```

- [ ] **Step 2: Run it — expect FAIL.** `cd backend && mix test test/legend/federation/relay_client/server_test.exs`
- [ ] **Step 3: Implement the server** by adapting `backend/lib/legend/tunnels/sprite_proxy/server.ex`'s frame/splice handling (read it). Drop the listener-start (`start_listener/1`) — this server's `target_port` is the ingress port passed in; it never accepts inbound connections, only `OPEN`s from the carrier. Keep: the `{:carrier_data, bin}` buffer+decode loop; `handle_frame(:open)` → `:gen_tcp.connect` to `target_port`; `handle_frame(:data)` → `:gen_tcp.send`; `handle_frame(:close)` → drop+close; `handle_info({:tcp, sock, data})` → `out(:data)`; `handle_info({:tcp_closed, sock})` → `out(:close)` + drop; `out/2` → `send(carrier, {:carrier_out, Mux.encode(f)})`. (The carrier is set in state; allow it to be updated via a `{:set_carrier, pid}` message so Task 3 can wire the live carrier after connect.)
- [ ] **Step 4: Run it — expect PASS.** `mix test test/legend/federation/relay_client/server_test.exs`
- [ ] **Step 5: `mix precommit`.**
- [ ] **Step 6: Commit** — `feat(relay): RelayClient.Server — splice relay streams to the ingress`.

---

### Task 3: `RelayClient.Carrier` (Mint.WebSocket) + the `RelayClient` supervisor

**Files:**
- Create: `backend/lib/legend/federation/relay_client/carrier.ex`, `backend/lib/legend/federation/relay_client.ex`
- Test: `backend/test/legend/federation/relay_client_test.exs` (gated `:integration` — runs the Part-2a relay app as the peer)

**Interfaces:**
- Consumes: `Legend.Federation.RelayClient.Server` (Task 2); `Mint.WebSocket`.
- Produces: `Legend.Federation.RelayClient.Carrier` — modeled on `Legend.Sprites.Proxy`: connects to `RELAY_URL` (`/carrier`), sends the registration JSON `{"handle","secret"}` as the first binary frame, then `{:carrier_out, bin}` (cast) → `Mint.WebSocket.encode` + `stream_request_body`, and inbound socket data → `Mint.WebSocket.stream`/`decode` → `send(server, {:carrier_data, bin})`. `Legend.Federation.RelayClient.start_link(%{relay_url, handle, secret, target_port})` starts the Server + the Carrier linked (Server first; Carrier registers then forwards). Reconnect-with-backoff on carrier drop.

**Approach:** Mirror `backend/lib/legend/sprites/proxy.ex` (read it) for the Mint.WebSocket connect/upgrade/encode/decode loop. The difference vs. sprites: (a) the URL is the relay's `/carrier` (parse `RELAY_URL` for scheme/host/port/path); (b) the first frame is the **registration JSON** (not a `{host,port}` proxy init); (c) decoded binary frames forward to `RelayClient.Server` (not a sprite proxy server). `RelayClient` (the provider) starts `Server` (with the ingress `target_port`) + `Carrier` (with `server: srv`), links them, and on connect sends `{:set_carrier, carrier_pid}` to the server so the splice can emit back.

- [ ] **Step 1: Write a gated integration test.** `relay_client_test.exs` `@moduletag :integration`. Start the **Part-2a relay app** in-test (or assume it runs) as the carrier peer: configure a handle/secret, start `RelayClient` pointed at the relay's carrier port + a local echo "ingress" port; from a relay device-side connection (or by driving the relay's device handler) open a stream and assert a byte round-trip reaches the echo ingress and back. (If running the separate relay app in-test is impractical, assert the `RelayClient.Server` ↔ a real `RelayClient.Carrier` connected to a minimal in-test WS server round-trip — document the harness.) The test MUST assert a real round-trip, not `assert true`.
- [ ] **Step 2: Run it — expect FAIL.** `cd backend && mix test test/legend/federation/relay_client_test.exs --only integration`
- [ ] **Step 3: Implement `Carrier`** (adapt `Sprites.Proxy`: connect, upgrade, the `handle_cast({:carrier_out, bin})` encode/send, the `handle_info` socket-data → `Mint.WebSocket.stream`/`decode` → `send(server, {:carrier_data, bin})`; on upgrade success, send the registration JSON frame then `send(server, {:set_carrier, self()})`). Implement `RelayClient` (`start_link/1`: start `Server` with `target_port`, start `Carrier` with `server: srv` + the relay URL/handle/secret, link). Reconnect-with-backoff on `{:EXIT, carrier, _}` (mirror `SpriteProxy.Server`'s reconnect).
- [ ] **Step 4: Run it — expect PASS** (`--only integration`). Plus `mix test` (unit) stays green.
- [ ] **Step 5: `mix precommit`.**
- [ ] **Step 6: Commit** — `feat(relay): RelayClient carrier (Mint.WebSocket) + supervisor`.

---

### Task 4: Remote config "via relay" mode + Boot wiring + controller

**Files:**
- Modify: `backend/lib/legend/core/remote.ex` (`config/0`, `put_config/1`, `relay_ingress_enabled?/0`)
- Modify: `backend/lib/legend/core/remote/boot.ex` (`apply!/0` — relay branch)
- Modify: `backend/lib/legend_web/controllers/remote_controller.ex` (`update/2`)
- Test: `backend/test/legend/core/remote_test.exs`, `backend/test/legend_web/controllers/remote_controller_test.exs`

**Interfaces:**
- Produces: `Remote.config/0` → `%{enabled, mode: "direct"|"via_relay", host, relay_url, relay_handle, relay_secret}` (relay fields nil in direct mode); `put_config/1` persists the extended JSON; `relay_ingress_enabled?/0` returns `true` iff `enabled and mode == "via_relay"` with all relay fields present (fail-safe to false otherwise). `Remote.Boot.apply!/0`: in `via_relay` mode, set `RelayIngressEndpoint` `check_origin` to `["//<relay_handle>.<relay-host-from-relay_url>"]` (+ url host) and start `Legend.Federation.RelayClient` (target_port = the ingress port from config).

- [ ] **Step 1: Write failing tests** in `remote_test.exs`: a persisted `{"enabled":true,"mode":"via_relay","relay_url":"https://relay.example.com","relay_handle":"laptop","relay_secret":"s"}` → `config/0` returns the relay fields and `relay_ingress_enabled?/0` is true; a via_relay config missing `relay_handle` → fails safe (`relay_ingress_enabled?/0` false). In `remote_controller_test.exs`: `PUT /api/settings/remote-access` with the relay fields persists them (loopback).
- [ ] **Step 2: Run them — expect FAIL.**
- [ ] **Step 3: Extend `Remote.config/0` + `put_config/1`** to carry `mode` (default `"direct"`) + `relay_url`/`relay_handle`/`relay_secret` (blank_to_nil), with the same fail-safe discipline (via_relay requires all relay fields, else treat as disabled). Make `relay_ingress_enabled?/0` read `config()` (no longer a static `Application.get_env`): `c = config(); c.enabled and c.mode == "via_relay" and c.relay_url && c.relay_handle && c.relay_secret`.
- [ ] **Step 4: Extend `Remote.Boot.apply!/0`** — when `config.mode == "via_relay"`: parse the relay host from `relay_url`, `Application.put_env` the `RelayIngressEndpoint` config with `check_origin: ["//#{relay_handle}.#{relay_host}"]` + `url: [host: "#{relay_handle}.#{relay_host}"]`; the ingress is then supervised (Part-1 wiring via `relay_ingress_enabled?/0`) and `apply!` also starts `Legend.Federation.RelayClient` with `{relay_url, relay_handle, relay_secret, target_port: ingress_port}`. (In `"direct"` mode, the existing main-endpoint 0.0.0.0 override path is unchanged.)
- [ ] **Step 5: Extend `RemoteController.update/2`** to accept + validate `mode`/`relay_url`/`relay_handle`/`relay_secret` (relay fields required when `mode == "via_relay"`; control-char validation like `host`), persist via `put_config`, return `restart_required: true`.
- [ ] **Step 6: Run the tests — expect PASS;** `mix precommit`.
- [ ] **Step 7: Commit** — `feat(relay): remote-access "via relay" mode + boot wiring + controller`.

---

### Task 5: Frontend "via relay" settings mode + relay-subdomain QR

**Files:**
- Modify: `frontend/src/lib/remote/devices.ts` (the `RemoteAccess` type + `setRemoteAccess`)
- Modify: `frontend/src/lib/remote/pairUrl.ts` (relay-subdomain QR)
- Modify: `frontend/src/lib/components/shell/RemoteAccessSection.svelte` (mode selector + relay fields)
- Test: `frontend/src/lib/remote/pairUrl.test.ts` (the relay-URL builder)

**Interfaces:**
- Produces: `RemoteAccess` = `{ enabled, mode: 'direct'|'via_relay', host, relay_url, relay_handle, relay_secret }`; `setRemoteAccess(payload: Partial<RemoteAccess> & {enabled})`; a `buildRelayPairUrl(relayUrl, handle, code)` → `https://<handle>.<relay-host>/pair?code=…`; a mode selector + relay URL/handle/secret inputs in the settings section; the QR uses the relay builder in via_relay mode.

- [ ] **Step 1: Write the failing test** in `pairUrl.test.ts`:

```ts
import { buildRelayPairUrl } from './pairUrl';
it('builds a relay-subdomain pair URL', () => {
  expect(buildRelayPairUrl('https://relay.example.com', 'laptop', 'CODE'))
    .toBe('https://laptop.relay.example.com/pair?code=CODE');
});
it('returns empty without handle/url/code', () => {
  expect(buildRelayPairUrl('', 'laptop', 'CODE')).toBe('');
});
```

- [ ] **Step 2: Run it — expect FAIL.** `cd frontend && bun run test src/lib/remote/pairUrl.test.ts`
- [ ] **Step 3: Implement `buildRelayPairUrl`** in `pairUrl.ts`: parse the relay URL's host, prepend `<handle>.`, keep the scheme (https), `…/pair?code=encodeURIComponent(code)`; empty when any of url/handle/code is blank.
- [ ] **Step 4: Extend the `RemoteAccess` type + `setRemoteAccess`** in `devices.ts` (the new fields; `setRemoteAccess` sends them). Extend `RemoteAccessSection.svelte`: a mode toggle (Direct / Via relay), relay URL + handle + secret inputs shown in via_relay mode, and the QR derived from `buildRelayPairUrl(relay_url, relay_handle, code)` when `mode === 'via_relay'` (else the existing `buildPairUrl`). Add the per-origin re-pair note ("pair again on the relay origin").
- [ ] **Step 5: Run + typecheck.** `cd frontend && bun run test && bun run check`
- [ ] **Step 6: Commit** — `feat(relay): frontend "via relay" settings mode + relay-subdomain QR`.

---

### Task 6: Gated live acceptance (instance ↔ relay ↔ device)

**Files:**
- Create: `docs/superpowers/specs/2026-06-27-relay-self-host-design.md` is the acceptance reference; add a short runbook under `docs/` or the relay README.
- (No new app code — a manual/gated acceptance.)

**Interfaces:** none — this proves the composition end-to-end.

- [ ] **Step 1: Write the runbook** (`relay/README.md` or `docs/`): run the Part-2a relay (`RELAY_HANDLES="laptop:s3cret"`, wildcard DNS + TLS), set the instance's `remote_access` to via_relay (`relay_url`, `relay_handle=laptop`, `relay_secret=s3cret`) loopback, restart; the instance's `RelayClient` dials the relay + registers; from a phone load `https://laptop.relay.example.com`, pair (relay-subdomain QR), and drive a session.
- [ ] **Step 2: Gated acceptance checklist** (manual, like the sprites live tests): registration succeeds (relay logs the handle online); a phone request routes through the relay → ingress → instance Phoenix; the device token is required (no token → 401 at the ingress); a session prompt + ACP permission + stop work; carrier drop → reconnect.
- [ ] **Step 3: Commit** — `docs(relay): live-acceptance runbook for instance<->relay<->device`.

---

## Final verification (after all tasks)
- [ ] `cd backend && mix precommit` + `cd frontend && bun run check && bun run test` green.
- [ ] Trust check: a relayed request to a device-gated route without a token is 401 at the ingress (the Part-1 `via_relay` invariant), and the splice targets the **ingress** (not the main endpoint).
- [ ] The carrier reconnects on drop; "via relay" is off by default; direct/mesh mode is unchanged.

## Notes
- This completes Phase 3a (the trusted self-host relay) end-to-end: relay app (2a) + instance federation (2b) on top of the Part-1 ingress. 3b (E2E) and 3c (managed) remain, behind the seams this slice preserved (the device token, the `via_relay` ingress, `Device.public_key`).
- The carrier+splice (Tasks 2–3) are the riskiest networking pieces — they mirror the proven `Sprites.Proxy` + `SpriteProxy.Server`; read those files first and adapt, don't reinvent. Record any deviation (e.g. the reconnect shape) in the task reports.
