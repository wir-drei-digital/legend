# Remote Access Foundation — Phase 2a (Reachability) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-06-24-remote-access-foundation-design.md`
**Builds on:** Phase 1 (`2026-06-24-remote-access-foundation-phase1.md`) — the loopback-or-token gate, `Legend.Core.Devices`, the audit trail.

**Goal:** Make a Legend instance opt-in reachable over a mesh: a `remote_access` setting that, when enabled, binds the endpoint on all interfaces (`0.0.0.0`) so paired remote devices can connect — gated entirely by the Phase-1 `DeviceAuth` rule — plus the deferred per-control-action audit.

**Architecture:** A `Legend.Core.Remote` module reads the `remote_access` setting (JSON in the SQLite key-value store) and produces endpoint config overrides. A boot child (`Legend.Core.Remote.Boot`, the `Library.Seeder` pattern) applies those overrides via `Application.put_env` **before** the Endpoint child starts (boot order: Repo → Migrator → … → Endpoint, so the setting is readable). Off by default → loopback-only, unchanged. Reconfiguring is **restart-to-apply**. Reachability is safe because the (Phase-1, tested) loopback-or-token gate is enforced at both choke points.

**Tech Stack:** Elixir / Phoenix 1.8 (Bandit) / Ash 3 + AshSqlite / SQLite. `Legend.Core.Settings` for persistence; `Application.put_env` for boot-time endpoint config.

## Global Constraints

- All `mix` commands from `backend/`; `mix precommit` (compile --warnings-as-errors + format + test) MUST pass.
- **DB-touching test modules use `async: false`** (SQLite write-lock contention bit us in Phase 1 — match the repo convention).
- **Bind decision = `0.0.0.0` + DeviceAuth (recorded change):** when remote access is on, bind all interfaces; the loopback-or-token rule is the network gate. This **supersedes the spec's "bind the specific mesh interface, not `0.0.0.0`" note** — Task 5 records it in the spec + ARCHITECTURE. (Defense-in-depth interface isolation = the deferred dual-listener option, not built here.)
- **Off by default.** Absent/disabled `remote_access` → the endpoint keeps its loopback config (dev `{127,0,0,1}`, prod `{127,0,0,1}:4807`). No behavior change for existing users.
- **Restart-to-apply.** The bind is read once at boot; the settings endpoint returns `restart_required: true`. No live rebind in this phase.
- **HTTP only this phase; TLS deferred.** A mesh (WireGuard) already encrypts the transport, so `http://` over the tailnet is confidential including the device token. TLS (https on a second port for PWA secure-context) is a later increment — out of scope here.
- **No desktop/Rust changes.** The setting drives the bind from inside the backend; `0.0.0.0` includes loopback, so the Tauri webview (`localhost:4807`) is unaffected.
- Router order is load-bearing; the new settings routes go in the **device-gated** scope (Phase 1).

---

## File Structure

**Create:**
- `backend/lib/legend/core/remote.ex` — config model: read the setting, produce endpoint overrides (pure), and the boot-apply.
- `backend/lib/legend/core/remote/boot.ex` — the boot child that applies overrides before the Endpoint starts.
- `backend/lib/legend_web/controllers/remote_controller.ex` — `/api/settings/remote-access` GET/PUT/DELETE.
- Tests mirroring each.

**Modify:**
- `backend/lib/legend/application.ex` — insert the `Remote.Boot` child after the Migrator, before the Endpoint.
- `backend/lib/legend_web/router.ex` — add the `/api/settings/remote-access` routes to the device-gated scope.
- `backend/lib/legend_web/channels/session_channel.ex` — audit `stop`/`permission`/`prompt` for remote devices.
- `docs/superpowers/specs/2026-06-24-remote-access-foundation-design.md` + `docs/ARCHITECTURE.md` — record the `0.0.0.0`/auth-as-gate decision.

---

### Task 1: `Legend.Core.Remote` — config + endpoint overrides

**Files:**
- Create: `backend/lib/legend/core/remote.ex`
- Test: `backend/test/legend/core/remote_test.exs`

**Interfaces:**
- Consumes: `Legend.Core.Settings.{get_setting/1, put_setting!/1, remove_setting/1}` (Phase 1).
- Produces:
  - `Legend.Core.Remote.config() :: %{enabled: boolean, host: String.t() | nil}` — decoded from the `"remote_access"` setting; disabled when absent or unparseable.
  - `Legend.Core.Remote.put_config(%{enabled: boolean, host: String.t() | nil}) :: :ok`
  - `Legend.Core.Remote.clear() :: :ok`
  - `Legend.Core.Remote.endpoint_overrides(existing :: keyword, config :: map) :: keyword` — pure. Given the endpoint's current config and the remote config, returns the full new endpoint config: enabled ⇒ `http` ip set to `{0,0,0,0}` (port preserved), `check_origin` extended with the host, `url` host set; disabled ⇒ `existing` unchanged.

- [ ] **Step 1: Write the failing test**

Create `backend/test/legend/core/remote_test.exs`:

```elixir
defmodule Legend.Core.RemoteTest do
  use Legend.DataCase, async: false

  alias Legend.Core.Remote

  setup do
    on_exit(fn -> Remote.clear() end)
    :ok
  end

  test "config defaults to disabled when unset" do
    assert Remote.config() == %{enabled: false, host: nil}
  end

  test "put_config persists and round-trips; clear disables" do
    :ok = Remote.put_config(%{enabled: true, host: "laptop.tailnet.ts.net"})
    assert Remote.config() == %{enabled: true, host: "laptop.tailnet.ts.net"}

    :ok = Remote.clear()
    assert Remote.config() == %{enabled: false, host: nil}
  end

  test "endpoint_overrides leaves config untouched when disabled" do
    existing = [http: [ip: {127, 0, 0, 1}, port: 4100], check_origin: ["//localhost"]]
    assert Remote.endpoint_overrides(existing, %{enabled: false, host: nil}) == existing
  end

  test "endpoint_overrides binds 0.0.0.0, preserves port, extends check_origin and url when enabled" do
    existing = [http: [ip: {127, 0, 0, 1}, port: 4807], check_origin: ["//localhost"]]
    out = Remote.endpoint_overrides(existing, %{enabled: true, host: "laptop.tailnet.ts.net"})

    assert out[:http][:ip] == {0, 0, 0, 0}
    assert out[:http][:port] == 4807
    assert "//laptop.tailnet.ts.net" in out[:check_origin]
    assert "//localhost" in out[:check_origin]
    assert out[:url][:host] == "laptop.tailnet.ts.net"
  end

  test "endpoint_overrides tolerates a missing host (binds 0.0.0.0, no origin/url addition)" do
    existing = [http: [ip: {127, 0, 0, 1}, port: 4807], check_origin: ["//localhost"]]
    out = Remote.endpoint_overrides(existing, %{enabled: true, host: nil})

    assert out[:http][:ip] == {0, 0, 0, 0}
    assert out[:check_origin] == ["//localhost"]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/legend/core/remote_test.exs`
Expected: FAIL — `Legend.Core.Remote` undefined.

- [ ] **Step 3: Write the implementation**

Create `backend/lib/legend/core/remote.ex`:

```elixir
defmodule Legend.Core.Remote do
  @moduledoc """
  Opt-in remote reachability. Reads the `"remote_access"` setting and produces
  endpoint config overrides applied at boot (`Legend.Core.Remote.Boot`). When
  enabled the endpoint binds `0.0.0.0` — the Phase-1 loopback-or-token gate
  (`DeviceAuth` + socket auth) is the network boundary. Off by default
  (loopback-only). Reconfiguring is restart-to-apply.
  """

  alias Legend.Core.Settings

  @key "remote_access"

  @spec config() :: %{enabled: boolean, host: String.t() | nil}
  def config do
    case Settings.get_setting(@key) do
      nil ->
        disabled()

      raw ->
        case Jason.decode(raw) do
          {:ok, %{"enabled" => enabled} = m} ->
            %{enabled: !!enabled, host: blank_to_nil(m["host"])}

          _ ->
            disabled()
        end
    end
  end

  @spec put_config(%{enabled: boolean, host: String.t() | nil}) :: :ok
  def put_config(%{enabled: enabled} = cfg) do
    payload = Jason.encode!(%{enabled: !!enabled, host: blank_to_nil(cfg[:host])})
    Settings.put_setting!(%{key: @key, value: payload})
    :ok
  end

  @spec clear() :: :ok
  def clear, do: Settings.remove_setting(@key)

  @doc """
  Pure: merge remote overrides onto the endpoint's existing config. Enabled →
  bind `0.0.0.0` (port preserved), extend `check_origin` and set `url` host for
  the configured host. Disabled → `existing` unchanged.
  """
  @spec endpoint_overrides(keyword, map) :: keyword
  def endpoint_overrides(existing, %{enabled: false}), do: existing

  def endpoint_overrides(existing, %{enabled: true, host: host}) do
    http = existing |> Keyword.get(:http, []) |> Keyword.put(:ip, {0, 0, 0, 0})

    existing
    |> Keyword.put(:http, http)
    |> maybe_put_host(host)
  end

  defp maybe_put_host(cfg, nil), do: cfg

  defp maybe_put_host(cfg, host) do
    # check_origin may be a list (prod) or `false` (dev convenience). When
    # enabling remote we always want origin checking, so fall back to a
    # localhost baseline rather than appending to a non-list.
    origins =
      case Keyword.get(cfg, :check_origin) do
        list when is_list(list) -> list
        _ -> ["//localhost"]
      end

    cfg
    |> Keyword.put(:check_origin, Enum.uniq(origins ++ ["//#{host}"]))
    |> Keyword.update(:url, [host: host], &Keyword.put(&1, :host, host))
  end

  defp disabled, do: %{enabled: false, host: nil}
  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v) when is_binary(v), do: v
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && mix test test/legend/core/remote_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
cd backend && mix format
git add backend/lib/legend/core/remote.ex backend/test/legend/core/remote_test.exs
git commit -m "feat(remote): remote_access config model + endpoint overrides"
```

---

### Task 2: `/api/settings/remote-access` endpoints

**Files:**
- Create: `backend/lib/legend_web/controllers/remote_controller.ex`
- Modify: `backend/lib/legend_web/router.ex` (device-gated scope)
- Test: `backend/test/legend_web/controllers/remote_controller_test.exs`

**Interfaces:**
- Consumes: `Legend.Core.Remote.{config/0, put_config/1, clear/0}` (Task 1).
- Produces HTTP (all device-gated — loopback or paired device):
  - `GET /api/settings/remote-access` → `200 {data: {enabled, host}}`
  - `PUT /api/settings/remote-access` body `{enabled, host?}` → `200 {data: {enabled, host}, restart_required: true}` | `422 {error}`
  - `DELETE /api/settings/remote-access` → `200 {data: {enabled: false, host: nil}}`

- [ ] **Step 1: Write the failing test**

Create `backend/test/legend_web/controllers/remote_controller_test.exs`:

```elixir
defmodule LegendWeb.RemoteControllerTest do
  use LegendWeb.ConnCase, async: false

  alias Legend.Core.Remote

  setup do
    on_exit(fn -> Remote.clear() end)
    :ok
  end

  test "GET reflects current config (default disabled)", %{conn: conn} do
    assert %{"data" => %{"enabled" => false, "host" => nil}} =
             json_response(get(conn, "/api/settings/remote-access"), 200)
  end

  test "PUT enables with a host, persists, and flags restart_required", %{conn: conn} do
    body = %{enabled: true, host: "laptop.tailnet.ts.net"}
    resp = json_response(put(conn, "/api/settings/remote-access", body), 200)

    assert resp["data"] == %{"enabled" => true, "host" => "laptop.tailnet.ts.net"}
    assert resp["restart_required"] == true
    assert Remote.config() == %{enabled: true, host: "laptop.tailnet.ts.net"}
  end

  test "PUT enabled without a host is rejected (422)", %{conn: conn} do
    assert json_response(put(conn, "/api/settings/remote-access", %{enabled: true}), 422)
  end

  test "PUT rejects a host with control characters (422)", %{conn: conn} do
    assert json_response(
             put(conn, "/api/settings/remote-access", %{enabled: true, host: "badhost"}),
             422
           )
  end

  test "DELETE disables", %{conn: conn} do
    Remote.put_config(%{enabled: true, host: "x.ts.net"})
    assert %{"data" => %{"enabled" => false}} =
             json_response(delete(conn, "/api/settings/remote-access"), 200)

    assert Remote.config().enabled == false
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/legend_web/controllers/remote_controller_test.exs`
Expected: FAIL — route/controller undefined (404 or compile error).

- [ ] **Step 3: Write the controller**

Create `backend/lib/legend_web/controllers/remote_controller.ex`:

```elixir
defmodule LegendWeb.RemoteController do
  @moduledoc """
  `/api/settings/remote-access` — the opt-in toggle. Device-gated. Enabling binds
  `0.0.0.0` at the next boot (restart-to-apply); `host` is the mesh name/IP the
  instance is reached at (for `check_origin`/`url`). A host is required when
  enabling so the WebSocket origin check stays meaningful.
  """
  use LegendWeb, :controller

  alias Legend.Core.Remote

  def show(conn, _params), do: json(conn, %{data: Remote.config()})

  def update(conn, params) do
    enabled = params["enabled"] == true
    host = params["host"]

    cond do
      enabled and blank?(host) ->
        error(conn, "host is required when enabling remote access")

      enabled and not valid_host?(host) ->
        error(conn, "host must not contain control characters")

      true ->
        :ok = Remote.put_config(%{enabled: enabled, host: host})
        json(conn, %{data: Remote.config(), restart_required: true})
    end
  end

  def delete(conn, _params) do
    :ok = Remote.clear()
    json(conn, %{data: Remote.config()})
  end

  defp blank?(v), do: v in [nil, ""]
  defp valid_host?(v), do: is_binary(v) and v =~ ~r/\A[^[:cntrl:]]+\z/u
  defp error(conn, msg), do: conn |> put_status(422) |> json(%{error: msg})
end
```

- [ ] **Step 4: Add the routes**

Modify `backend/lib/legend_web/router.ex` — in the **device-authed** scope (the one with `pipe_through [:api, :device_auth]` that already holds `/settings/library-path`), add:

```elixir
    get "/settings/remote-access", RemoteController, :show
    put "/settings/remote-access", RemoteController, :update
    delete "/settings/remote-access", RemoteController, :delete
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd backend && mix test test/legend_web/controllers/remote_controller_test.exs`
Expected: PASS (5 tests). (ConnCase builds a loopback conn, so `DeviceAuth` allows it.)

- [ ] **Step 6: Commit**

```bash
cd backend && mix format
git add backend/lib/legend_web/controllers/remote_controller.ex backend/lib/legend_web/router.ex backend/test/legend_web/controllers/remote_controller_test.exs
git commit -m "feat(remote): /api/settings/remote-access toggle (device-gated)"
```

---

### Task 3: Boot configurator — apply the bind at startup

**Files:**
- Create: `backend/lib/legend/core/remote/boot.ex`
- Modify: `backend/lib/legend/application.ex`
- Test: `backend/test/legend/core/remote/boot_test.exs`

**Interfaces:**
- Consumes: `Legend.Core.Remote.{config/0, endpoint_overrides/2}` (Task 1).
- Produces: `Legend.Core.Remote.Boot.apply!() :: :ok` — reads config, and when enabled merges `endpoint_overrides/2` into `Application.get_env(:legend, LegendWeb.Endpoint)` via `put_env`. `start_link/1` calls `apply!()` and returns `:ignore` (no process). A child in the supervision tree **before** `LegendWeb.Endpoint`.

- [ ] **Step 1: Write the failing test**

Create `backend/test/legend/core/remote/boot_test.exs`:

```elixir
defmodule Legend.Core.Remote.BootTest do
  use Legend.DataCase, async: false

  alias Legend.Core.Remote

  setup do
    original = Application.get_env(:legend, LegendWeb.Endpoint)
    on_exit(fn ->
      Application.put_env(:legend, LegendWeb.Endpoint, original)
      Remote.clear()
    end)
    :ok
  end

  test "apply! is a no-op when disabled (endpoint stays loopback)" do
    before = Application.get_env(:legend, LegendWeb.Endpoint)
    :ok = Remote.Boot.apply!()
    assert Application.get_env(:legend, LegendWeb.Endpoint) == before
  end

  test "apply! binds 0.0.0.0 when enabled" do
    Remote.put_config(%{enabled: true, host: "laptop.ts.net"})
    :ok = Remote.Boot.apply!()

    http = Application.get_env(:legend, LegendWeb.Endpoint)[:http]
    assert http[:ip] == {0, 0, 0, 0}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/legend/core/remote/boot_test.exs`
Expected: FAIL — `Legend.Core.Remote.Boot` undefined.

- [ ] **Step 3: Write the boot child**

Create `backend/lib/legend/core/remote/boot.ex`:

```elixir
defmodule Legend.Core.Remote.Boot do
  @moduledoc """
  Applies the `remote_access` bind to the endpoint config BEFORE the Endpoint
  child starts. Runs sync in `start_link` (the `Library.Seeder` pattern) and
  returns `:ignore` — no process stays alive. Disabled = no-op (loopback).
  """
  require Logger

  alias Legend.Core.Remote

  def start_link(_opts) do
    :ok = apply!()
    :ignore
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker, restart: :transient}
  end

  @spec apply!() :: :ok
  def apply! do
    config = Remote.config()

    if config.enabled do
      existing = Application.get_env(:legend, LegendWeb.Endpoint, [])
      Application.put_env(:legend, LegendWeb.Endpoint, Remote.endpoint_overrides(existing, config))
      Logger.info("[remote] remote access ENABLED — endpoint bound 0.0.0.0 (host: #{config.host})")
    end

    :ok
  end
end
```

- [ ] **Step 4: Wire it into the supervision tree**

Modify `backend/lib/legend/application.ex` — insert `Legend.Core.Remote.Boot` after the `Library.Seeder` and before `LegendWeb.Endpoint` (it needs the Repo/Migrator up to read the setting, and must run before the Endpoint binds):

```elixir
      Legend.Core.Library.Seeder,
      # Applies the remote_access bind to the endpoint config before it starts
      # (Repo is up so the setting is readable). No-op when disabled (loopback).
      Legend.Core.Remote.Boot,
      {DNSCluster, query: Application.get_env(:legend, :dns_cluster_query) || :ignore},
```

(The Endpoint remains the last child, so the `put_env` lands before it boots.)

- [ ] **Step 5: Run test to verify it passes**

Run: `cd backend && mix test test/legend/core/remote/boot_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 6: Full suite (the app boots with the new child)**

Run: `cd backend && mix precommit`
Expected: green. The new child boots in test (disabled → no-op), the app starts normally.

- [ ] **Step 7: Commit**

```bash
git add backend/lib/legend/core/remote/boot.ex backend/lib/legend/application.ex backend/test/legend/core/remote/boot_test.exs
git commit -m "feat(remote): boot-time endpoint bind from remote_access setting"
```

---

### Task 4: Per-control-action audit in `SessionChannel`

**Files:**
- Modify: `backend/lib/legend_web/channels/session_channel.ex`
- Test: `backend/test/legend_web/channels/session_channel_control_audit_test.exs`

**Interfaces:**
- Consumes: `Legend.Core.Devices.audit!/1`, `socket.assigns[:device_id]` (Phase 1).
- Produces: when a socket with a non-nil `device_id` sends `stop` / `permission` / `prompt`, an `AuditEvent` with the matching action is recorded (`"stop"` / `"permission"` / `"prompt"`). Loopback sockets (`device_id` nil) are not audited. (Phase 1 already audits `"attach"` on join.)

- [ ] **Step 1: Write the failing test**

Create `backend/test/legend_web/channels/session_channel_control_audit_test.exs`:

```elixir
defmodule LegendWeb.SessionChannelControlAuditTest do
  use LegendWeb.ChannelCase, async: false

  alias Legend.Core.{Agents, Devices}

  setup do
    session = Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})
    on_exit(fn -> Legend.Core.Agents.SessionServer.ensure_stopped(session.id) end)
    %{session: session}
  end

  defp join_as(device_id, session) do
    {:ok, _reply, socket} =
      LegendWeb.UserSocket
      |> socket("device:#{device_id || "local"}", %{device_id: device_id})
      |> subscribe_and_join(LegendWeb.SessionChannel, "session:#{session.id}")

    socket
  end

  test "a remote device's stop is audited; a loopback stop is not", %{session: session} do
    socket = join_as("d1", session)
    push(socket, "stop", %{})
    # let the cast round-trip
    _ = :sys.get_state(socket.channel_pid)

    stops = Enum.filter(Devices.list_audit!(), &(&1.action == "stop"))
    assert [%{device_id: "d1", session_id: sid}] = stops
    assert sid == session.id

    local = join_as(nil, session)
    push(local, "stop", %{})
    _ = :sys.get_state(local.channel_pid)
    assert length(Enum.filter(Devices.list_audit!(), &(&1.action == "stop"))) == 1
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/legend_web/channels/session_channel_control_audit_test.exs`
Expected: FAIL — `stop` is not audited yet.

- [ ] **Step 3: Add the audit calls**

Modify `backend/lib/legend_web/channels/session_channel.ex`. Add a private helper, and call it at the top of the `stop`, `permission`, and `prompt` inbound handlers:

```elixir
  def handle_in("stop", _payload, socket) do
    audit_control(socket, "stop")
    SessionServer.stop(socket.assigns.session_id)
    {:noreply, socket}
  end
```

```elixir
  def handle_in("prompt", %{"content" => content}, socket)
      when is_binary(content) or is_list(content) do
    audit_control(socket, "prompt")
    SessionServer.acp_prompt(socket.assigns.session_id, content)
    {:noreply, socket}
  end
```

```elixir
  def handle_in("permission", %{"request_id" => req, "option_id" => opt}, socket)
      when is_binary(req) and is_binary(opt) do
    audit_control(socket, "permission")
    SessionServer.acp_permission(socket.assigns.session_id, req, opt)
    {:noreply, socket}
  end
```

And the helper (near `maybe_audit_attach/2` from Phase 1):

```elixir
  defp audit_control(%{assigns: %{device_id: device_id, session_id: session_id}}, action)
       when is_binary(device_id) do
    Legend.Core.Devices.audit!(%{device_id: device_id, session_id: session_id, action: action})
  end

  defp audit_control(_socket, _action), do: :ok
```

> Leave `input` / `resize` / `cancel` / `set_mode` / `set_model` un-audited — the spec records control-action granularity, not raw keystrokes or view changes. `input` especially would be per-keystroke noise.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && mix test test/legend_web/channels/session_channel_control_audit_test.exs`
Expected: PASS (1 test).

- [ ] **Step 5: Full suite**

Run: `cd backend && mix precommit`
Expected: green.

- [ ] **Step 6: Commit**

```bash
git add backend/lib/legend_web/channels/session_channel.ex backend/test/legend_web/channels/session_channel_control_audit_test.exs
git commit -m "feat(remote): audit remote stop/permission/prompt control actions"
```

---

### Task 5: Record the bind decision in the spec + ARCHITECTURE

**Files:**
- Modify: `docs/superpowers/specs/2026-06-24-remote-access-foundation-design.md`
- Modify: `docs/ARCHITECTURE.md`

**Interfaces:** none (docs).

- [ ] **Step 1: Update the spec**

In `docs/superpowers/specs/2026-06-24-remote-access-foundation-design.md`, in the **Reachability** section, replace the "bind the specific mesh interface, not `0.0.0.0`" guidance with the decision actually taken, and note the deferred alternative. Add (or amend the relevant bullet) to read:

```markdown
- **Bind `0.0.0.0` when remote access is enabled; the loopback-or-token gate is the network boundary.** (Supersedes the earlier "specific mesh interface, not `0.0.0.0`" note.) Rationale: on desktop the Tauri webview needs `localhost` *and* remote devices need the mesh interface simultaneously; `0.0.0.0` serves both, and a non-loopback caller still needs a valid device token (hostile LAN/wifi gets 401). The defense-in-depth alternative — a second listener bound only to the mesh IP, leaving the port unreachable on other networks — is deferred (dual-listener; more plumbing, and Phoenix channels over a hand-started Bandit need verification). TLS (https on a second port for PWA secure-context) is also deferred; a mesh already encrypts the transport, so `http://` over the tailnet is confidential including the token. Reconfiguring is restart-to-apply.
```

Add a line to the **Decisions log** table:

```markdown
| Bind `0.0.0.0` + DeviceAuth, not a specific-interface bind | Desktop needs loopback (webview) + mesh (remote) at once; `0.0.0.0` serves both and the tested auth rule is the gate. Interface-isolation (dual listener) deferred as defense-in-depth. |
```

- [ ] **Step 2: Update ARCHITECTURE**

In `docs/ARCHITECTURE.md`, the "Remote access is gated" bullet says Phase 2 "binds the reachable interface and terminates TLS directly." Update that clause to reflect the decision:

```markdown
  ...Reachability is an opt-in `remote_access` setting (Phase 2a, restart-to-apply) that **binds `0.0.0.0`** so the desktop webview (`localhost`) and remote devices share one listener — the loopback-or-token gate is the network boundary (this supersedes an earlier "specific mesh interface" note; interface isolation via a second mesh-only listener is the deferred hardening). TLS (https for PWA secure-context) is deferred; a mesh already encrypts the transport...
```

(Keep the rest of the bullet — the choke points, `Device.public_key` seam, etc. — intact.)

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-06-24-remote-access-foundation-design.md docs/ARCHITECTURE.md
git commit -m "docs(remote): record 0.0.0.0 + auth-as-gate bind decision (phase 2a)"
```

---

## What Phase 2a deliberately does NOT do

- **TLS / https** (second port for PWA secure-context) — deferred; mesh encrypts, `http://` is fine for the core use case.
- **Dual-listener interface isolation** (#2) — deferred defense-in-depth.
- **Live rebind** — restart-to-apply.
- **All frontend** — the device-token store, Devices screen, pairing/QR screen, responsive mobile session route are **Phase 2b** (they carry design decisions).
- **Desktop/Rust changes** — none needed (the setting drives the bind from inside the backend).

## Self-Review

**Spec coverage:** the `remote_access` opt-in (Tasks 1–3), off-by-default + restart-to-apply (Tasks 1/3, surfaced in Task 2's `restart_required`), `check_origin` for the host (Task 1), the bind decision recorded (Task 5), per-control-action audit (Task 4). TLS + dual-listener + frontend explicitly deferred. ✔

**Placeholder scan:** every step has concrete code/commands. No TBD. ✔

**Type consistency:** `Remote.config/0` → `%{enabled, host}` consumed by the controller (Task 2) and Boot (Task 3); `Remote.endpoint_overrides/2` (existing, config) used by Boot; `Remote.put_config/1`/`clear/0` used by the controller; `Devices.audit!/1` + `list_audit!/0` (bang, Phase 1) used in Task 4. All consistent. ✔

## Execution Handoff

Five tasks, mostly backend config, all but the boot-wiring fully unit-tested. Recommended: **subagent-driven-development** (fresh Opus subagent per task + review), matching Phase 1. Tasks are largely independent; Task 2 depends on Task 1, Task 3 depends on Task 1.
