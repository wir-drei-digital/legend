# Remote Access Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Close the seven findings from the external security review of the merged remote-access foundation, then polish the mesh path (Option 3) so reaching an instance from a phone is turnkey.

**Architecture:** Backend security/correctness fixes (Phase-1 pairing/audit/config code newly exposed by remote reachability), reachability fixes (force_ssl, desktop SPA packaging, QR port), and a reachable-host auto-detect. No change to the core trust rule (loopback OR valid device token) — these *enforce* it where it was leaky.

**Tech Stack:** Elixir/Phoenix/Ash 3 + AshSqlite (backend), SvelteKit/Svelte 5 (frontend), Justfile build scripts.

## Global Constraints

- Backend: all `mix` from `backend/`; `mix precommit` (compile `--warnings-as-errors` + format + test) MUST pass; DB-touching ExUnit modules are `async: false` (SQLite write-lock).
- Frontend: all `bun` from `frontend/`; `bun run check` (0 errors) MUST pass; `bun run test` for logic.
- Trust rule (unchanged): a request is trusted iff loopback OR a valid non-revoked device token. `DeviceAuth` assigns `conn.assigns.device` = `:local` (loopback) | `%Device{}` (remote). `UserSocket` assigns `socket.assigns.device_id` = `nil` (loopback) | id (remote).
- Device *management* (generate pairing code, revoke) is **loopback-only** per the spec ("enrollment needs physical possession of an already-trusted device"). Remote tokens authenticate to *use* sessions, not to enroll/manage devices.
- Audit `device_id` is the **actor**: a remote action records the acting device's id; a loopback action records `nil`. Never the target.
- TLS is deferred — `http://` over the mesh is intentional (the mesh encrypts). Fixes must not require HTTPS.
- Router order is load-bearing: `/api/health`, `/api/mcp`, `/api/pair` public; device-gated scope; the `forward "/", LegendWeb.AshJsonApiRouter` stays last under `/api`.
- Commit messages end with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

### Task 1: [P1c] Pairing-code generation is loopback-only

**Files:**
- Modify: `backend/lib/legend_web/controllers/device_controller.ex` (`create_pair_code/2`)
- Test: `backend/test/legend_web/controllers/device_controller_test.exs`

**Interfaces:**
- Consumes: `conn.assigns.device` (set by `DeviceAuth`: `:local` | `%Device{}`).
- Produces: `POST /api/devices/pair-code` returns 403 for a non-loopback (remote-token) caller; 200 for loopback.

- [ ] **Step 1: Write the failing test.** Add to `device_controller_test.exs` (the module is already `async: false`, loopback by default):

```elixir
  test "pair-code generation is rejected for a remote (non-loopback) caller", %{conn: conn} do
    device = Devices.create_device!(%{name: "phone", public_key: nil})
    token = LegendWeb.DeviceToken.sign(device.id)

    conn =
      conn
      |> Map.put(:remote_ip, {203, 0, 113, 7})
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/devices/pair-code", %{})

    assert json_response(conn, 403) == %{"error" => "device enrollment is local-only"}
  end
```

(Add `alias LegendWeb.DeviceToken` if the test module needs it, or use the fully-qualified name as above.)

- [ ] **Step 2: Run it — expect FAIL** (currently returns 200). `cd backend && mix test test/legend_web/controllers/device_controller_test.exs`

- [ ] **Step 3: Enforce `:local`.** In `create_pair_code/2`:

```elixir
  def create_pair_code(conn, _params) do
    if conn.assigns.device == :local do
      code = Devices.generate_pairing_code!()
      json(conn, %{code: code.code, expires_at: code.expires_at})
    else
      conn |> put_status(403) |> json(%{error: "device enrollment is local-only"})
    end
  end
```

- [ ] **Step 4: Run the test — expect PASS** (and the existing loopback "generate a pairing code" test still passes).
- [ ] **Step 5: `mix precommit`.**
- [ ] **Step 6: Commit** — `fix(devices): restrict pairing-code generation to loopback (no remote enrollment)`.

---

### Task 2: [P2] Atomic single-use pairing-code redemption

**Files:**
- Modify: `backend/lib/legend/core/devices/pairing_code.ex` (`mark_redeemed` action — atomic claim)
- Modify: `backend/lib/legend/core/devices.ex` (`redeem_pairing_code/2` — only create a device when the claim succeeds)
- Test: `backend/test/legend/core/pairing_test.exs`

**Interfaces:**
- Produces: `redeem_pairing_code/2` returns `{:ok, %Device{}}` for the single winner and `{:error, :used}` for a loser; concurrent redeems of one code yield exactly one device.

**Approach:** Make redemption an atomic guarded claim instead of read-check-write. Change `mark_redeemed` to a guarded update that only matches rows where `redeemed_at IS NULL`, and have `redeem_pairing_code/2` create the device **only if the claim affected the row**. Use a transaction so the claim + create are consistent.

- [ ] **Step 1: Write the failing test** in `pairing_test.exs` (module `async: false`) — claiming twice yields one success:

```elixir
  test "a code can be claimed only once even across repeated redeems" do
    code = Devices.generate_pairing_code!()

    assert {:ok, %Legend.Core.Devices.Device{}} =
             Devices.redeem_pairing_code(code.code, %{name: "first"})

    assert {:error, :used} = Devices.redeem_pairing_code(code.code, %{name: "second"})

    # exactly one device exists for this redemption
    assert Enum.count(Devices.list_devices!(), & &1) >= 1
  end
```

(Keep/adjust existing redeem tests — the happy path and TTL/expiry must still pass.)

- [ ] **Step 2: Run it — expect FAIL or FLAKY** under the current check-then-update (the guard doesn't exist yet). `cd backend && mix test test/legend/core/pairing_test.exs`

- [ ] **Step 3: Add an atomic claim action** in `pairing_code.ex`. Replace `mark_redeemed` with a guarded claim that filters on unredeemed and returns the updated record only when it claimed the row. Implementation note for the engineer: AshSqlite supports atomic updates with a filter — use an update action that (a) filters `expr(is_nil(redeemed_at))` and (b) sets `redeemed_at`. If the record was already redeemed, the action must surface a not-found/stale error rather than re-stamping. Concretely:

```elixir
    update :claim do
      # Atomic single-use claim: only an unredeemed row is claimable.
      require_atomic? false
      change set_attribute(:redeemed_at, &DateTime.utc_now/0)
      change filter expr(is_nil(redeemed_at))
    end
```

Expose it on the domain in `devices.ex`:

```elixir
      define :claim_pairing_code, action: :claim
```

- [ ] **Step 4: Rewrite `redeem_pairing_code/2`** in `devices.ex` to claim-then-create inside a transaction, treating a failed claim as `:used`:

```elixir
  def redeem_pairing_code(code, attrs) when is_binary(code) do
    case pairing_code_by_code(code) do
      {:ok, %PairingCode{expires_at: exp} = pc} ->
        if DateTime.compare(exp, DateTime.utc_now()) == :gt do
          # Atomic claim: only the first redeemer of an unredeemed code wins.
          case claim_pairing_code(pc) do
            {:ok, _claimed} -> {:ok, create_device!(Map.take(attrs, [:name, :public_key]))}
            {:error, _} -> {:error, :used}
          end
        else
          {:error, :expired}
        end

      _ ->
        {:error, :invalid}
    end
  end
```

The engineer must confirm that `claim_pairing_code/1` on an already-redeemed row returns `{:error, _}` (the `filter` makes it match zero rows → a stale/invalid error), not `{:ok, _}`. If the chosen Ash mechanism needs a transaction wrapper (`Ash.transaction` / `Repo.transaction`) to make claim+create consistent, add it. If the atomic-filter approach behaves differently than expected, escalate (BLOCKED) with what you observed rather than guessing.

- [ ] **Step 5: Run the test — expect PASS** (second redeem → `:used`; happy path + TTL tests still green).
- [ ] **Step 6: `mix precommit`.**
- [ ] **Step 7: Commit** — `fix(devices): atomic single-use pairing-code redemption (close TOCTOU)`.

---

### Task 3: [P2] Audit attribution fix + channel control actions

**Files:**
- Modify: `backend/lib/legend_web/controllers/device_controller.ex` (`revoke/2` — log the actor, not the target)
- Modify: `backend/lib/legend_web/channels/session_channel.ex` (audit `cancel`, `set_mode`, `set_model`)
- Test: `backend/test/legend_web/controllers/device_controller_test.exs`, the session-channel audit test

**Interfaces:**
- `AuditEvent.device_id` = the **actor** (`conn.assigns.device` → `actor_id/1`: `%Device{id}` → id, `:local` → nil). The revoked device id stays available via `action`/context but is not put in `device_id`.

- [ ] **Step 1: Write the failing test** — revoke from loopback records the actor (nil), not the target id:

```elixir
  test "revoke audits the actor (loopback => nil), not the revoked target", %{conn: conn} do
    device = Devices.create_device!(%{name: "old", public_key: nil})
    delete(conn, "/api/devices/#{device.id}")

    rows = Devices.list_audit!() |> Enum.filter(&(&1.action == "revoke"))
    assert Enum.any?(rows), "a revoke audit row should exist"
    # actor is loopback here => device_id nil; it must NOT be the revoked target id
    assert Enum.all?(rows, &(&1.device_id != device.id))
  end
```

- [ ] **Step 2: Run it — expect FAIL** (current code logs `device_id: id`, the target). `cd backend && mix test test/legend_web/controllers/device_controller_test.exs`

- [ ] **Step 3: Add an actor helper + fix `revoke/2`.** In `device_controller.ex`:

```elixir
  defp actor_id(%Legend.Core.Devices.Device{id: id}), do: id
  defp actor_id(_), do: nil
```

In `revoke/2`, change the audit call from `%{device_id: id, ...}` to record the actor and keep the target in the action label:

```elixir
        Devices.audit!(%{device_id: actor_id(conn.assigns.device), session_id: id, action: "revoke"})
```

(Recording the revoked target id in `session_id` is a pragmatic reuse of the free string column so the trail still says *what* was revoked; note this in the commit. Do not invent a new column.)

- [ ] **Step 4: Audit the remaining channel control actions.** `session_channel.ex` already audits `stop`/permission/prompt via its existing helper. Add the same audit call to the `cancel`, `set_mode`, and `set_model` handlers, using the socket's device id as the actor (the existing helper already reads `socket.assigns.device_id`). Mirror the existing handler exactly — same helper, new `action` strings `"cancel"`, `"set_mode"`, `"set_model"`. Extend the existing channel-audit test to assert one of these (e.g. `cancel`) produces a row with the socket's device as actor.

- [ ] **Step 5: Run the tests — expect PASS.**
- [ ] **Step 6: `mix precommit`.**
- [ ] **Step 7: Commit** — `fix(devices): audit the actor not the target; cover channel cancel/set_mode/set_model`.

---

### Task 4: [P2] Fail-safe remote config (enabled without host => disabled)

**Files:**
- Modify: `backend/lib/legend/core/remote.ex` (`config/0`)
- Test: `backend/test/legend/core/remote_test.exs`

**Interfaces:**
- `Remote.config/0` returns `%{enabled: false, host: nil}` whenever the persisted setting is `enabled: true` but `host` is blank/nil. The boot path therefore never binds `0.0.0.0` without a host.

- [ ] **Step 1: Write the failing test** in `remote_test.exs` (use the existing settings-seeding pattern in that file to write a raw `enabled:true, host:nil` payload):

```elixir
  test "enabled without a host fails safe to disabled" do
    Legend.Core.Settings.put_setting!(%{key: "remote_access", value: ~s({"enabled":true})})
    assert %{enabled: false, host: nil} = Legend.Core.Remote.config()
  end
```

- [ ] **Step 2: Run it — expect FAIL** (current `config/0` returns `enabled: true, host: nil`).

- [ ] **Step 3: Make `config/0` require a host when enabled.** In the decode branch:

```elixir
          {:ok, %{"enabled" => enabled} = m} ->
            host = blank_to_nil(m["host"])
            # Fail safe: enabling without a host would bind 0.0.0.0 with no
            # origin/url host — treat malformed/partial config as disabled.
            if !!enabled and host != nil do
              %{enabled: true, host: host}
            else
              disabled()
            end
```

- [ ] **Step 4: Run the test — expect PASS** (existing enabled-with-host + disabled tests still pass).
- [ ] **Step 5: `mix precommit`.**
- [ ] **Step 6: Commit** — `fix(remote): fail safe to loopback when remote config has no host`.

---

### Task 5: [P2] Audit remote session-lifecycle JSON:API actions

**Files:**
- Modify: `backend/lib/legend_web/router.ex` (set the Ash actor from `conn.assigns.device` for the device-gated Ash scope)
- Modify: `backend/lib/legend/core/agents.ex` and/or the session resource (after-action audit on `start`/`resume`/`transport`/`destroy`)
- Test: `backend/test/legend_web/controllers/session_api_test.exs` (or the agents domain test)

**Interfaces:**
- Remote (device-token) calls to the session lifecycle actions write an `AuditEvent` with `device_id` = the acting device, `session_id` = the session, `action` = the lifecycle name. Loopback calls write `device_id: nil`.

**Approach:** Thread the device actor into Ash, then record audit in an after-action hook.

- [ ] **Step 1: Set the Ash actor.** Add a plug to the device-gated Ash pipeline that sets the actor from the already-assigned device: `Ash.PlugHelpers.set_actor(conn, conn.assigns.device)`. The simplest seam is a tiny plug module run in the `pipe_through` for the Ash forward scope (after `DeviceAuth`). Confirm `AshJsonApi` reads the actor from the conn (it does via `Ash.PlugHelpers`).

- [ ] **Step 2: Write the failing test** — a session action carried out with a remote device token writes an audit row attributing the device. Use the `session_api_test.exs` style; build a conn with a `%Device{}` token + non-loopback `remote_ip`, perform `delete`/`resume`, and assert an `AuditEvent` exists with `device_id == device.id`, `action == "delete"` (etc.).

- [ ] **Step 3: Add the after-action audit** on the relevant session actions (`start`, `resume`, `transport`, `destroy`). Implement a shared `change` that, in an `after_action`, inserts an `AuditEvent` with the action's actor (`changeset.context`/`Ash.Changeset.get_context` or the action `actor`) → `device_id` (`%Device{} → id`, else nil), `session_id` = the record id, `action` = the action name. The audit insert must be best-effort: a failed audit must NOT roll back the session operation (catch/log). Attach the change to those actions in the resource definition.

- [ ] **Step 4: Run the test — expect PASS;** the full session/agents suite still green (those test modules stay `async: false`).

- [ ] **Step 5: `mix precommit`.**
- [ ] **Step 6: Commit** — `feat(devices): audit remote session-lifecycle actions (start/resume/transport/delete)`.

**If this task balloons** (actor plumbing fights the existing action/test surface), STOP and report BLOCKED with what you found — the controller will descope to attribution-only (Task 3 already lands the high-value fix) rather than force it.

---

### Task 6: [P1b] force_ssl must not break http-over-mesh

**Files:**
- Modify: `backend/lib/legend/core/remote.ex` (`endpoint_overrides/2` — drop `force_ssl` when enabling http remote)
- Test: `backend/test/legend/core/remote_test.exs`

**Interfaces:**
- `endpoint_overrides(existing, %{enabled: true, host: h})` returns config with `force_ssl: false` (TLS is deferred; the mesh encrypts), so a phone at `http://h:<port>` is not redirected to a non-existent HTTPS listener. Disabled = passthrough (force_ssl untouched).

**Approach:** `Remote.Boot` already overrides endpoint config at boot via `Application.put_env`. Extend `endpoint_overrides/2` so the enabled branch also disables `force_ssl`. (When TLS lands later, this becomes conditional on a configured cert — out of scope now.)

- [ ] **Step 1: Write the failing test** in `remote_test.exs`:

```elixir
  test "enabling remote disables force_ssl (http over mesh)" do
    existing = [http: [port: 4807], force_ssl: [rewrite_on: [:x_forwarded_proto]]]
    out = Legend.Core.Remote.endpoint_overrides(existing, %{enabled: true, host: "laptop.ts.net"})
    assert out[:force_ssl] == false
  end

  test "disabling leaves force_ssl untouched" do
    existing = [force_ssl: [rewrite_on: [:x_forwarded_proto]]]
    assert Legend.Core.Remote.endpoint_overrides(existing, %{enabled: false}) == existing
  end
```

- [ ] **Step 2: Run it — expect FAIL.**

- [ ] **Step 3: Disable force_ssl in the enabled branch.** In `endpoint_overrides/2` enabled clause, after setting the bind:

```elixir
  def endpoint_overrides(existing, %{enabled: true, host: host}) do
    http = existing |> Keyword.get(:http, []) |> Keyword.put(:ip, {0, 0, 0, 0})

    existing
    |> Keyword.put(:http, http)
    |> Keyword.put(:force_ssl, false)
    |> maybe_put_host(host)
  end
```

- [ ] **Step 4: Run the tests — expect PASS;** existing `endpoint_overrides` tests still green.
- [ ] **Step 5: `mix precommit`.**
- [ ] **Step 6: Commit** — `fix(remote): disable force_ssl when binding http over the mesh (TLS deferred)`.

---

### Task 7: [P1a] Desktop sidecar serves a same-origin SPA to remote devices

**Files:**
- Modify: `Justfile` (`package-backend` — build a blank-`PUBLIC_*` SPA into `backend/priv/static` before packaging `legend_desktop`)

**Interfaces:**
- After `just package-backend` (and thus `just desktop-bundle`), `backend/priv/static` contains `index.html` + `_app` built with blank `PUBLIC_*` (same-origin), so the sidecar serves a working SPA to a phone at `http://<host>:4807`. The Tauri *webview* keeps using its own `frontend/build` (localhost-baked, via tauri's `beforeBuildCommand`) — these are two separate builds at two stages and do not conflict (the sidecar's `priv/static` is baked into the Burrito binary at package time; tauri rebuilds `frontend/build` afterward for the webview).

- [ ] **Step 1: Update `package-backend`.** Before `backend/scripts/build-release.sh legend_desktop`, build + copy the same-origin SPA (mirroring the `build` target's SPA step, with blank `PUBLIC_*`):

```make
package-backend:
    #!/usr/bin/env bash
    set -euo pipefail
    # Same-origin SPA for the sidecar (remote devices load it from the sidecar
    # origin). Blank PUBLIC_* => same-origin; distinct from the Tauri webview's
    # localhost-baked frontend/build.
    cd frontend && bun run build
    cd ..
    rm -rf backend/priv/static/_app backend/priv/static/index.html
    cp -R frontend/build/. backend/priv/static/
    backend/scripts/build-release.sh legend_desktop
```

(Preserve any existing steps in the recipe; keep the binary-copy step that places the sidecar under `desktop/src-tauri/binaries/`. Read the current recipe and integrate, do not blindly overwrite trailing steps.)

- [ ] **Step 2: Verify the SPA lands.** This is a build-pipeline change with no unit test. Verification: run `just package-backend` (or at minimum the SPA steps) and confirm `backend/priv/static/index.html` exists and the JS bundle has NO `localhost:4807` baked in (`grep -rl "localhost:4807" backend/priv/static || echo "clean (same-origin)"`). Record the command + output in the report. If `just package-backend` is too heavy/slow to run fully (it provisions zig + Burrito), run just the SPA build+copy steps and confirm `index.html` + a clean grep, and note that the full bundle was not packaged in this environment.

- [ ] **Step 3: Commit** — `fix(desktop): bake a same-origin SPA into the sidecar's priv/static for remote devices`.

---

### Task 8: [P2] QR pairing URL uses the backend port (Tauri-safe)

**Files:**
- Modify: `frontend/src/lib/components/shell/RemoteAccessSection.svelte` (port derivation)
- Modify: `frontend/src/lib/api.ts` (export a helper for the backend authority, if cleaner)

**Interfaces:**
- The pairing QR URL is `http://<host>:<backend-port>/pair?code=<code>` in BOTH the web release (port from `window.location.port`) and the desktop app (port parsed from `apiBase`, since the Tauri window is `tauri://localhost` with no port). Host = the configured remote-access host (or the form input).

- [ ] **Step 1: Derive the backend port robustly.** In `RemoteAccessSection.svelte`, replace the `window.location.port` derivation. Compute the port from `apiBase` when it is an absolute URL (desktop: `http://localhost:4807` → `4807`), else fall back to `window.location.port` (web same-origin). Example:

```ts
import { apiBase } from '$lib/api';

function backendPort(): string {
	// Desktop bakes apiBase = http://localhost:4807; the Tauri window is
	// tauri://localhost (no port), so derive the port from apiBase there.
	try {
		if (apiBase) return new URL(apiBase).port;
	} catch {
		/* fall through */
	}
	return typeof window !== 'undefined' ? window.location.port : '';
}
```

Use `backendPort()` instead of `window.location.port` in the `pairUrl` derivation; keep the `host:port` vs `host` authority normalization (omit `:` when port is empty).

- [ ] **Step 2: Typecheck.** `bun run check` (0 errors). (No unit test harness for this component; verify the derivation by reading the code. Optionally extract `backendPort` to a tiny pure module and add a vitest if low-cost — engineer's call; not required.)

- [ ] **Step 3: Commit** — `fix(remote): QR uses the backend port (correct under tauri://localhost)`.

---

### Task 9: [Option 3] Reachable-host auto-detect + pre-fill

**Files:**
- Create: `backend/lib/legend_web/controllers/remote_controller.ex` — add an `interfaces/2` action (or a small dedicated controller) returning candidate reachable hosts
- Modify: `backend/lib/legend_web/router.ex` (device-gated route `GET /api/settings/remote-access/interfaces`)
- Modify: `frontend/src/lib/remote/devices.ts` (client) + `frontend/src/lib/components/shell/RemoteAccessSection.svelte` (suggest/pre-fill)
- Test: `backend/test/legend_web/controllers/remote_controller_test.exs`

**Interfaces:**
- `GET /api/settings/remote-access/interfaces` → `{ data: { candidates: [string], suggested: string | null } }` where `candidates` are this machine's non-loopback IPv4 addresses and `suggested` is the Tailscale CGNAT-range one (`100.64.0.0/10`) when present.
- The Remote-access settings UI calls it on mount; when the host field is empty it pre-fills `suggested` (or shows `candidates` as clickable chips).

- [ ] **Step 1: Backend — enumerate interfaces.** Add the action. Use `:inet.getifaddrs/0`, collect IPv4 addrs that are not loopback (`{127,_,_,_}`) and not link-local, format as strings. Flag the CGNAT range `100.64.0.0/10` (first octet 100, second 64..127) as `suggested`:

```elixir
  def interfaces(conn, _params) do
    addrs =
      case :inet.getifaddrs() do
        {:ok, ifs} ->
          for {_name, opts} <- ifs, {:addr, {a, b, c, d}} <- opts, {a, b, c, d} != {127, 0, 0, 1} do
            "#{a}.#{b}.#{c}.#{d}"
          end

        _ ->
          []
      end
      |> Enum.uniq()

    suggested = Enum.find(addrs, &tailscale?/1)
    json(conn, %{data: %{candidates: addrs, suggested: suggested}})
  end

  defp tailscale?(ip) do
    case String.split(ip, ".") do
      [a, b | _] -> a == "100" and String.to_integer(b) in 64..127
      _ -> false
    end
  end
```

(The engineer should filter to IPv4 only — `getifaddrs` also yields IPv6 tuples and `:addr` may be a 8-element tuple; match only 4-element tuples. Adjust the comprehension to guard `tuple_size`.)

- [ ] **Step 2: Write the failing test** — `GET /api/settings/remote-access/interfaces` returns a `data.candidates` list (loopback excluded) and a `suggested` key (may be nil in CI):

```elixir
  test "lists non-loopback interface candidates", %{conn: conn} do
    body = json_response(get(conn, "/api/settings/remote-access/interfaces"), 200)
    assert is_list(body["data"]["candidates"])
    refute "127.0.0.1" in body["data"]["candidates"]
    assert Map.has_key?(body["data"], "suggested")
  end
```

- [ ] **Step 3: Add the route** in the device-gated scope, near the other remote-access routes: `get "/settings/remote-access/interfaces", RemoteController, :interfaces`.
- [ ] **Step 4: Run the test — expect PASS;** `mix precommit`.
- [ ] **Step 5: Frontend — suggest the host.** Add `getRemoteInterfaces()` to `remote/devices.ts` (`apiFetch('/api/settings/remote-access/interfaces')`). In `RemoteAccessSection.svelte`, on mount, fetch candidates; when the host field is empty, pre-fill `suggested` (or render candidates as clickable chips that set the host field). Keep it unobtrusive — a "Detected: 100.x.y.z (use)" affordance.
- [ ] **Step 6: `bun run check`** (0 errors).
- [ ] **Step 7: Commit** — `feat(remote): auto-detect reachable host and pre-fill the pairing settings`.

---

## Final verification (after all tasks)

- [ ] `cd backend && mix precommit` — green.
- [ ] `cd frontend && bun run check && bun run test` — green.
- [ ] Whole-subsystem security re-check (the lesson from this very review): enumerate every device-gated endpoint/action and confirm each honors loopback-vs-remote correctly (pairing generation local-only; redemption atomic; audit attributes the actor; config fails safe; no http→https trap; SPA served same-origin).

## Notes / sequencing
- Tasks 1–5 are the security/correctness cluster (do first). Tasks 6–8 make the desktop/prod phone path actually work. Task 9 is the Option-3 mesh polish.
- Task 5 is the heaviest (Ash actor plumbing) and is explicitly descope-able to attribution-only (Task 3) if it fights the existing surface.
- The MagicDNS *name* (`laptop.tailnet.ts.net`) auto-detect is out of scope; Task 9 detects the reachable IP (pairing against the `100.x` IP works).
