# Remote Access Foundation — Phase 1 (Auth, Pairing & Audit) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-06-24-remote-access-foundation-design.md`

**Goal:** Build the backend security core that makes a Legend instance safe to expose — every non-loopback caller must present a valid, non-revoked paired-device token — plus the device-pairing flow and an audit trail. This phase **does not** make the instance reachable; it changes nothing for existing loopback users.

**Architecture:** A new `Legend.Core.Devices` Ash domain (`Device`, `PairingCode`, `AuditEvent`) holds device identity. A stateless `Phoenix.Token` carrying the device id is the credential; revocation is a server-side check on `Device.revoked_at`. Two choke points enforce one rule — *loopback OR valid device token* — a `LegendWeb.DeviceAuth` plug (HTTP) and `LegendWeb.UserSocket.connect/3` (WebSocket). Pairing is "WhatsApp Web": a loopback-trusted screen generates a short-lived single-use code; the new device redeems it over the (future) network to mint its token.

**Tech Stack:** Elixir 1.20 / Phoenix 1.8 / Ash 3 + AshSqlite / SQLite. `Phoenix.Token` for credentials. ExUnit (`ConnCase`, `ChannelCase`, `DataCase`).

## Global Constraints

- Backend dir is `backend/`. Run all `mix` commands from there: `cd backend && <cmd>`.
- `mix precommit` (`compile --warnings-as-errors` + `deps.unlock --unused` + `format` + `test`) MUST pass before a task is done.
- **Every domain in `ash_domains` MUST carry the `AshJsonApi.Domain` extension** even with zero JSON:API routes — the router probes each registered domain; omitting it 500s a *later* domain's routes (the `Settings` gotcha). `Legend.Core.Devices` exposes **no** JSON:API routes (plain controllers), so it carries the extension and omits the `json_api` block.
- **Router order is load-bearing.** Specific `/api/*` routes are declared before `forward "/", LegendWeb.AshJsonApiRouter`, which is before the SPA catch-all. Never reorder.
- **The one auth rule:** trusted iff loopback peer (`{127,0,0,1}` or IPv6 `{0,0,0,0,0,0,0,1}`) OR a valid, non-revoked device token. Nothing else.
- **`/api/health` and `/api/mcp` are NOT device-gated** — health is a probe; `/api/mcp` keeps its existing per-session `mcp_token` (agent auth, a separate axis). `POST /api/pair` is the sole pre-auth human write.
- **Credential = bearer `Phoenix.Token`** in v1. `Device.public_key` is reserved (nullable, **unused this phase**) as the seam for the future zero-knowledge relay — populate it at pairing if provided, never depend on it.
- Migrations are generated, never hand-written: `cd backend && mix ash.codegen <name>` (this repo's AshSqlite snapshots; if your Ash version routes the generator differently, `mix ash_sqlite.generate_migrations <name>` is the fallback), then `mix ecto.migrate`.
- Match existing idioms exactly (see the referenced files in each task). Token vocabulary, `defaults [:read]`, `send_error/3` JSON shape, etc.

---

## File Structure

**Create:**
- `backend/lib/legend/core/devices.ex` — the Ash domain + thin domain-function API (`get_device`, `list_devices`, `create_device!`, `revoke_device!`, `touch_device!`, `generate_pairing_code!`, `redeem_pairing_code/2`, `audit!`).
- `backend/lib/legend/core/devices/device.ex` — `Device` resource.
- `backend/lib/legend/core/devices/pairing_code.ex` — `PairingCode` resource.
- `backend/lib/legend/core/devices/audit_event.ex` — `AuditEvent` resource.
- `backend/lib/legend_web/device_token.ex` — `Phoenix.Token` sign/verify-and-load (web layer; depends on `LegendWeb.Endpoint`).
- `backend/lib/legend_web/remote_peer.ex` — `loopback?/1` shared by plug + socket.
- `backend/lib/legend_web/device_auth.ex` — the HTTP plug.
- `backend/lib/legend_web/controllers/pair_controller.ex` — `POST /api/pair` (redeem).
- `backend/lib/legend_web/controllers/device_controller.ex` — list / generate-code / revoke (loopback-gated by `DeviceAuth`).
- Tests mirroring each under `backend/test/...`.

**Modify:**
- `backend/config/config.exs` — register `Legend.Core.Devices` in `ash_domains`.
- `backend/lib/legend_web/endpoint.ex` — add `connect_info: [:peer_data]` to the socket.
- `backend/lib/legend_web/channels/user_socket.ex` — `connect/3` auth + `id/1`.
- `backend/lib/legend_web/router.ex` — `:device_auth` pipeline; split public vs gated scopes; add `/api/pair`, `/api/devices*`.
- `backend/lib/legend_web/channels/session_channel.ex` — audit a remote-device attach on join.

---

### Task 1: `Device` resource + `Devices` domain skeleton

**Files:**
- Create: `backend/lib/legend/core/devices/device.ex`
- Create: `backend/lib/legend/core/devices.ex`
- Modify: `backend/config/config.exs` (the `ash_domains:` list)
- Create (generated): `backend/priv/repo/migrations/*_add_devices.exs`
- Test: `backend/test/legend/core/devices_test.exs`

**Interfaces:**
- Produces:
  - `Legend.Core.Devices.create_device!(%{name: String.t() | nil, public_key: String.t() | nil}) :: %Device{}` — sets `paired_at` to now.
  - `Legend.Core.Devices.get_device(id :: String.t()) :: {:ok, %Device{}} | {:error, term}`
  - `Legend.Core.Devices.list_devices() :: [%Device{}]` (newest first)
  - `Legend.Core.Devices.revoke_device!(%Device{}) :: %Device{}` — sets `revoked_at`.
  - `Legend.Core.Devices.touch_device!(%Device{}) :: %Device{}` — sets `last_seen_at`.
  - `%Device{}` fields: `id, name, public_key, paired_at, last_seen_at, revoked_at, inserted_at, updated_at`.

- [ ] **Step 1: Write the failing test**

Create `backend/test/legend/core/devices_test.exs`:

```elixir
defmodule Legend.Core.DevicesTest do
  use Legend.DataCase, async: true

  alias Legend.Core.Devices
  alias Legend.Core.Devices.Device

  describe "device lifecycle" do
    test "create_device! sets paired_at and defaults" do
      device = Devices.create_device!(%{name: "Daniel's iPhone", public_key: nil})

      assert %Device{} = device
      assert device.name == "Daniel's iPhone"
      assert device.public_key == nil
      assert device.paired_at
      assert device.revoked_at == nil
      assert device.last_seen_at == nil
    end

    test "get_device fetches by id; revoke_device! and touch_device! update timestamps" do
      device = Devices.create_device!(%{name: "laptop", public_key: "pk-123"})

      assert {:ok, fetched} = Devices.get_device(device.id)
      assert fetched.id == device.id
      assert fetched.public_key == "pk-123"

      touched = Devices.touch_device!(device)
      assert touched.last_seen_at

      revoked = Devices.revoke_device!(device)
      assert revoked.revoked_at
    end

    test "list_devices returns newest first" do
      a = Devices.create_device!(%{name: "a", public_key: nil})
      b = Devices.create_device!(%{name: "b", public_key: nil})

      ids = Devices.list_devices() |> Enum.map(& &1.id)
      assert ids == [b.id, a.id]
    end

    test "name rejects control characters" do
      assert_raise Ash.Error.Invalid, fn ->
        Devices.create_device!(%{name: "badname", public_key: nil})
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/legend/core/devices_test.exs`
Expected: FAIL — `Legend.Core.Devices` / `Legend.Core.Devices.Device` undefined.

- [ ] **Step 3: Write the `Device` resource**

Create `backend/lib/legend/core/devices/device.ex`:

```elixir
defmodule Legend.Core.Devices.Device do
  @moduledoc """
  A paired device authorized to reach this instance remotely. The credential is
  a stateless `Phoenix.Token` carrying this id (minted at pairing); revocation is
  the server-side `revoked_at` check. `public_key` is reserved for the future
  zero-knowledge relay and is unused today.
  """
  use Ash.Resource, otp_app: :legend, domain: Legend.Core.Devices, data_layer: AshSqlite.DataLayer

  sqlite do
    table "devices"
    repo Legend.Repo
  end

  actions do
    defaults [:read]

    read :list do
      prepare build(sort: [inserted_at: :desc])
    end

    create :pair do
      accept [:name, :public_key]

      validate match(:name, ~r/\A[^[:cntrl:]]*\z/u) do
        message "must not contain control characters"
        where present(:name)
      end

      validate string_length(:name, max: 120) do
        where present(:name)
      end

      change set_attribute(:paired_at, &DateTime.utc_now/0)
    end

    update :touch do
      require_atomic? false
      change set_attribute(:last_seen_at, &DateTime.utc_now/0)
    end

    update :revoke do
      require_atomic? false
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string, public?: true
    # Reserved for the future zero-knowledge relay; unused in v1.
    attribute :public_key, :string, public?: true

    attribute :paired_at, :utc_datetime_usec, public?: true
    attribute :last_seen_at, :utc_datetime_usec, public?: true
    attribute :revoked_at, :utc_datetime_usec, public?: true

    timestamps()
  end
end
```

- [ ] **Step 4: Write the `Devices` domain + function API**

Create `backend/lib/legend/core/devices.ex`:

```elixir
defmodule Legend.Core.Devices do
  @moduledoc """
  Device identity for remote access: paired devices, pairing codes, and an audit
  trail. Carries the `AshJsonApi.Domain` extension (required of every registered
  domain) but exposes no JSON:API routes — access is via plain controllers.
  """
  use Ash.Domain, otp_app: :legend, extensions: [AshJsonApi.Domain]

  resources do
    resource Legend.Core.Devices.Device do
      define :create_device, action: :pair
      define :get_device_record, action: :read, get_by: :id
      define :list_devices, action: :list
      define :touch_device, action: :touch
      define :revoke_device, action: :revoke
    end
  end

  @doc "Fetch a device by id; `{:error, :not_found}` when absent."
  def get_device(id) do
    case get_device_record(id) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, device} -> {:ok, device}
      {:error, _} = err -> err
    end
  end
end
```

> Note: the `define` macro generates the public API — `create_device!/1` (from `:pair`), `list_devices/0`, `touch_device!/1` and `revoke_device!/1` (update actions take the record), and `get_device_record/1` (`get_by: :id` → `{:ok, record | nil}`). Do **not** hand-write `!` wrappers for these — that collides with the generated functions. The hand-written `get_device/1` adapts the get to a stable `{:ok, _} | {:error, :not_found}` contract (DeviceToken depends on it).

- [ ] **Step 5: Register the domain**

Modify `backend/config/config.exs` — add `Legend.Core.Devices` to `ash_domains`:

```elixir
config :legend,
  ecto_repos: [Legend.Repo],
  ash_domains: [Legend.Core.Agents, Legend.Core.Settings, Legend.Core.Signals, Legend.Core.Devices],
  generators: [timestamp_type: :utc_datetime]
```

- [ ] **Step 6: Generate the migration and migrate**

Run:
```bash
cd backend && mix ash.codegen add_devices && mix ecto.migrate
```
Expected: a new `priv/repo/migrations/*_add_devices.exs` creating the `devices` table; migration applies cleanly. (Fallback if `ash.codegen` is unavailable: `mix ash_sqlite.generate_migrations add_devices`.)

- [ ] **Step 7: Run the test to verify it passes**

Run: `cd backend && mix test test/legend/core/devices_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 8: Commit**

```bash
cd backend && mix format
git add backend/lib/legend/core/devices.ex backend/lib/legend/core/devices/device.ex backend/config/config.exs backend/priv/repo/migrations backend/priv/resource_snapshots backend/test/legend/core/devices_test.exs
git commit -m "feat(devices): Device resource + Devices domain skeleton"
```

---

### Task 2: `DeviceToken` — sign + verify-and-load

**Files:**
- Create: `backend/lib/legend_web/device_token.ex`
- Test: `backend/test/legend_web/device_token_test.exs`

**Interfaces:**
- Consumes: `Legend.Core.Devices.{get_device!/create_device!}`, `%Device{}` (Task 1).
- Produces:
  - `LegendWeb.DeviceToken.sign(device_id :: String.t()) :: String.t()`
  - `LegendWeb.DeviceToken.verify(token :: String.t()) :: {:ok, %Device{}} | {:error, :invalid | :revoked}` — verifies the signature, loads the device, rejects revoked.

- [ ] **Step 1: Write the failing test**

Create `backend/test/legend_web/device_token_test.exs`:

```elixir
defmodule LegendWeb.DeviceTokenTest do
  use Legend.DataCase, async: true

  alias Legend.Core.Devices
  alias LegendWeb.DeviceToken

  test "round-trips a valid device" do
    device = Devices.create_device!(%{name: "phone", public_key: nil})
    token = DeviceToken.sign(device.id)

    assert {:ok, loaded} = DeviceToken.verify(token)
    assert loaded.id == device.id
  end

  test "rejects a garbage token" do
    assert {:error, :invalid} = DeviceToken.verify("not-a-token")
  end

  test "rejects a token for a revoked device" do
    device = Devices.create_device!(%{name: "phone", public_key: nil})
    token = DeviceToken.sign(device.id)
    Devices.revoke_device!(device)

    assert {:error, :revoked} = DeviceToken.verify(token)
  end

  test "rejects a token whose device no longer exists" do
    token = DeviceToken.sign(Ecto.UUID.generate())
    assert {:error, :invalid} = DeviceToken.verify(token)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/legend_web/device_token_test.exs`
Expected: FAIL — `LegendWeb.DeviceToken` undefined.

- [ ] **Step 3: Write the implementation**

Create `backend/lib/legend_web/device_token.ex`:

```elixir
defmodule LegendWeb.DeviceToken do
  @moduledoc """
  Stateless device credential. A `Phoenix.Token` signed with the endpoint's
  `secret_key_base` carries the device id; verification loads the device and
  rejects revoked ones. Secret rotation invalidates all device tokens (re-pair).
  """

  alias Legend.Core.Devices
  alias Legend.Core.Devices.Device

  @salt "device auth"
  # Long-lived: revocation is the kill switch, not expiry. ~10 years.
  @max_age 315_360_000

  @spec sign(String.t()) :: String.t()
  def sign(device_id) when is_binary(device_id) do
    Phoenix.Token.sign(LegendWeb.Endpoint, @salt, device_id)
  end

  @spec verify(String.t()) :: {:ok, struct()} | {:error, :invalid | :revoked}
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(LegendWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, device_id} -> load(device_id)
      {:error, _} -> {:error, :invalid}
    end
  end

  def verify(_), do: {:error, :invalid}

  defp load(device_id) do
    case Devices.get_device(device_id) do
      {:ok, %Device{revoked_at: nil} = device} -> {:ok, device}
      {:ok, %Device{}} -> {:error, :revoked}
      {:error, _} -> {:error, :invalid}
    end
  end
end
```

> The `load/1` clauses pattern-match `%Device{}` (aliased), so the `alias` stays. The `@spec` uses `struct()` to avoid depending on an Ash-generated `t()` type under `--warnings-as-errors`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && mix test test/legend_web/device_token_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
cd backend && mix format
git add backend/lib/legend_web/device_token.ex backend/test/legend_web/device_token_test.exs
git commit -m "feat(devices): DeviceToken sign + verify-and-load with revocation"
```

---

### Task 3: `PairingCode` resource + generate/redeem

**Files:**
- Create: `backend/lib/legend/core/devices/pairing_code.ex`
- Modify: `backend/lib/legend/core/devices.ex` (add resource + `generate_pairing_code!/0`, `redeem_pairing_code/2`)
- Create (generated): `backend/priv/repo/migrations/*_add_pairing_codes.exs`
- Test: `backend/test/legend/core/pairing_test.exs`

**Interfaces:**
- Consumes: `Devices.create_device!/1`, `%Device{}` (Task 1).
- Produces:
  - `Legend.Core.Devices.generate_pairing_code!() :: %PairingCode{code: String.t(), expires_at: DateTime.t()}`
  - `Legend.Core.Devices.redeem_pairing_code(code :: String.t(), %{name: String.t() | nil, public_key: String.t() | nil}) :: {:ok, %Device{}} | {:error, :invalid | :expired | :used}`
  - Code TTL = 10 minutes; codes are single-use.

- [ ] **Step 1: Write the failing test**

Create `backend/test/legend/core/pairing_test.exs`:

```elixir
defmodule Legend.Core.PairingTest do
  use Legend.DataCase, async: true

  alias Legend.Core.Devices
  alias Legend.Core.Devices.{Device, PairingCode}

  test "generate then redeem mints a device" do
    %PairingCode{code: code, expires_at: exp} = Devices.generate_pairing_code!()
    assert is_binary(code) and byte_size(code) >= 8
    assert DateTime.compare(exp, DateTime.utc_now()) == :gt

    assert {:ok, %Device{} = device} =
             Devices.redeem_pairing_code(code, %{name: "phone", public_key: "pk"})

    assert device.name == "phone"
    assert device.public_key == "pk"
  end

  test "a code is single-use" do
    %PairingCode{code: code} = Devices.generate_pairing_code!()
    assert {:ok, _} = Devices.redeem_pairing_code(code, %{name: "a", public_key: nil})
    assert {:error, :used} = Devices.redeem_pairing_code(code, %{name: "b", public_key: nil})
  end

  test "an unknown code is invalid" do
    assert {:error, :invalid} = Devices.redeem_pairing_code("nope", %{name: nil, public_key: nil})
  end

  test "an expired code is rejected" do
    code = Devices.generate_pairing_code!()

    # Force expiry into the past (test-only action).
    code
    |> Ash.Changeset.for_update(:expire_for_test, %{
      expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
    })
    |> Ash.update!()

    assert {:error, :expired} =
             Devices.redeem_pairing_code(code.code, %{name: nil, public_key: nil})
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/legend/core/pairing_test.exs`
Expected: FAIL — `PairingCode` / `generate_pairing_code!` undefined.

- [ ] **Step 3: Write the `PairingCode` resource**

Create `backend/lib/legend/core/devices/pairing_code.ex`:

```elixir
defmodule Legend.Core.Devices.PairingCode do
  @moduledoc """
  A short-lived, single-use code minted on a loopback-trusted screen and redeemed
  by a new device to pair. TTL-bounded; `redeemed_at` enforces single use.
  """
  use Ash.Resource, otp_app: :legend, domain: Legend.Core.Devices, data_layer: AshSqlite.DataLayer

  @ttl_seconds 600

  sqlite do
    table "pairing_codes"
    repo Legend.Repo
  end

  actions do
    defaults [:read]

    create :generate do
      change fn changeset, _ctx ->
        code = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

        changeset
        |> Ash.Changeset.force_change_attribute(:code, code)
        |> Ash.Changeset.force_change_attribute(
          :expires_at,
          DateTime.add(DateTime.utc_now(), @ttl_seconds, :second)
        )
      end
    end

    read :by_code do
      argument :code, :string, allow_nil?: false
      get? true
      filter expr(code == ^arg(:code))
    end

    update :mark_redeemed do
      require_atomic? false
      change set_attribute(:redeemed_at, &DateTime.utc_now/0)
    end

    # Test-only: backdate expiry to exercise the expired path.
    update :expire_for_test do
      accept [:expires_at]
      require_atomic? false
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :redeemed_at, :utc_datetime_usec, public?: true
    timestamps()
  end

  identities do
    identity :unique_code, [:code]
  end
end
```

- [ ] **Step 4: Add the domain functions**

Modify `backend/lib/legend/core/devices.ex` — the `resources do` block becomes the following (Device keeps **all five** defines from Task 1; `PairingCode` is added), plus the alias:

```elixir
  alias Legend.Core.Devices.{Device, PairingCode}

  resources do
    resource Device do
      define :create_device, action: :pair
      define :get_device_record, action: :read, get_by: :id
      define :list_devices, action: :list
      define :touch_device, action: :touch
      define :revoke_device, action: :revoke
    end

    resource PairingCode do
      define :generate_pairing_code, action: :generate
      define :pairing_code_by_code, action: :by_code, args: [:code]
      define :mark_pairing_code_redeemed, action: :mark_redeemed
    end
  end
```

And append the redeem function to the module body (`generate_pairing_code!/0` is generated by the `define` above — do **not** hand-write it):

```elixir
  @doc """
  Redeem a code, minting a paired device. Single-use and TTL-bounded:
  `{:error, :invalid | :expired | :used}` on the unhappy paths.
  """
  def redeem_pairing_code(code, attrs) when is_binary(code) do
    case pairing_code_by_code(code) do
      {:ok, %PairingCode{redeemed_at: redeemed}} when not is_nil(redeemed) ->
        {:error, :used}

      {:ok, %PairingCode{expires_at: exp} = pc} ->
        if DateTime.compare(exp, DateTime.utc_now()) == :gt do
          device = create_device!(Map.take(attrs, [:name, :public_key]))
          _ = mark_pairing_code_redeemed!(pc)
          {:ok, device}
        else
          {:error, :expired}
        end

      _ ->
        {:error, :invalid}
    end
  end
```

> `by_code` is `get? true`, so `pairing_code_by_code/1` returns `{:ok, code | nil}`; a `nil` falls through to `{:error, :invalid}`. `create_device!/1`, `generate_pairing_code!/0`, and `mark_pairing_code_redeemed!/1` are all generated by the `define`s above.

- [ ] **Step 5: Generate the migration and migrate**

Run:
```bash
cd backend && mix ash.codegen add_pairing_codes && mix ecto.migrate
```
Expected: a migration creating `pairing_codes` (with the unique index on `code`); applies cleanly.

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd backend && mix test test/legend/core/pairing_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 7: Commit**

```bash
cd backend && mix format
git add backend/lib/legend/core/devices.ex backend/lib/legend/core/devices/pairing_code.ex backend/priv/repo/migrations backend/priv/resource_snapshots backend/test/legend/core/pairing_test.exs
git commit -m "feat(devices): PairingCode resource + generate/redeem (single-use, TTL)"
```

---

### Task 4: `RemotePeer.loopback?` + `DeviceAuth` plug + router gating

**Files:**
- Create: `backend/lib/legend_web/remote_peer.ex`
- Create: `backend/lib/legend_web/device_auth.ex`
- Modify: `backend/lib/legend_web/router.ex`
- Test: `backend/test/legend_web/device_auth_test.exs`

**Interfaces:**
- Consumes: `LegendWeb.DeviceToken.verify/1` (Task 2).
- Produces:
  - `LegendWeb.RemotePeer.loopback?(:inet.ip_address()) :: boolean`
  - `LegendWeb.DeviceAuth` plug — assigns `:device` (`:local` for loopback, `%Device{}` for token); 401-halts otherwise.

- [ ] **Step 1: Write the failing test**

Create `backend/test/legend_web/device_auth_test.exs`:

```elixir
defmodule LegendWeb.DeviceAuthTest do
  use LegendWeb.ConnCase, async: true

  alias Legend.Core.Devices
  alias LegendWeb.DeviceToken

  # /api/runtimes is device-gated and side-effect-free — a good probe.
  test "loopback is allowed without a token", %{conn: conn} do
    conn = %{conn | remote_ip: {127, 0, 0, 1}}
    conn = get(conn, "/api/runtimes")
    assert json_response(conn, 200)
  end

  test "a non-loopback request without a token is rejected", %{conn: conn} do
    conn = %{conn | remote_ip: {100, 64, 1, 2}}
    conn = get(conn, "/api/runtimes")
    assert json_response(conn, 401)
  end

  test "a non-loopback request with a valid token is allowed", %{conn: conn} do
    device = Devices.create_device!(%{name: "phone", public_key: nil})
    token = DeviceToken.sign(device.id)

    conn =
      %{conn | remote_ip: {100, 64, 1, 2}}
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/runtimes")

    assert json_response(conn, 200)
  end

  test "a revoked device's token is rejected", %{conn: conn} do
    device = Devices.create_device!(%{name: "phone", public_key: nil})
    token = DeviceToken.sign(device.id)
    Devices.revoke_device!(device)

    conn =
      %{conn | remote_ip: {100, 64, 1, 2}}
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/runtimes")

    assert json_response(conn, 401)
  end

  test "health is reachable without auth (not gated)", %{conn: conn} do
    conn = %{conn | remote_ip: {100, 64, 1, 2}}
    conn = get(conn, "/api/health")
    assert json_response(conn, 200)
  end

  test "a forwarded-for header does NOT confer loopback trust (no proxy-collapse bypass)", %{
    conn: conn
  } do
    conn =
      %{conn | remote_ip: {100, 64, 1, 2}}
      |> put_req_header("x-forwarded-for", "127.0.0.1")
      |> get("/api/runtimes")

    assert json_response(conn, 401)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/legend_web/device_auth_test.exs`
Expected: FAIL — currently `/api/runtimes` is ungated, so the non-loopback case returns 200 (or the plug is undefined).

- [ ] **Step 3: Write `RemotePeer`**

Create `backend/lib/legend_web/remote_peer.ex`:

```elixir
defmodule LegendWeb.RemotePeer do
  @moduledoc """
  Loopback predicate shared by the HTTP plug and the socket. Loopback = the
  connection originated on this machine — the trust root. Sound only because no
  localhost-collapsing reverse proxy sits in front (see the spec); the IP is the
  real transport peer, never a forwarded header.
  """

  @loopback_v4 {127, 0, 0, 1}
  @loopback_v6 {0, 0, 0, 0, 0, 0, 0, 1}

  @spec loopback?(:inet.ip_address() | nil) :: boolean
  def loopback?(@loopback_v4), do: true
  def loopback?(@loopback_v6), do: true
  # Any 127.0.0.0/8 address is loopback.
  def loopback?({127, _, _, _}), do: true
  def loopback?(_), do: false
end
```

- [ ] **Step 4: Write the `DeviceAuth` plug**

Create `backend/lib/legend_web/device_auth.ex`:

```elixir
defmodule LegendWeb.DeviceAuth do
  @moduledoc """
  The one rule for HTTP: trusted iff loopback peer OR a valid, non-revoked device
  token. Assigns `:device` (`:local` | `%Device{}`); 401-halts otherwise. Does NOT
  bump `last_seen_at` (avoids a write per request — the socket bumps it).
  """
  import Plug.Conn

  alias LegendWeb.{DeviceToken, RemotePeer}

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      RemotePeer.loopback?(conn.remote_ip) ->
        assign(conn, :device, :local)

      true ->
        case token(conn) do
          {:ok, t} ->
            case DeviceToken.verify(t) do
              {:ok, device} -> assign(conn, :device, device)
              {:error, _} -> deny(conn)
            end

          :error ->
            deny(conn)
        end
    end
  end

  defp token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> t] when t != "" -> {:ok, t}
      _ -> :error
    end
  end

  defp deny(conn) do
    conn
    |> put_status(401)
    |> Phoenix.Controller.json(%{error: "unauthorized"})
    |> halt()
  end
end
```

- [ ] **Step 5: Gate the router**

Modify `backend/lib/legend_web/router.ex` to its full new form:

```elixir
defmodule LegendWeb.Router do
  use LegendWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :device_auth do
    plug LegendWeb.DeviceAuth
  end

  # Public (NOT device-gated): health probe, agent MCP (own session token),
  # pairing redeem (the sole pre-auth human write).
  scope "/api", LegendWeb do
    pipe_through :api

    get "/health", HealthController, :show
    post "/mcp", MCPController, :handle
    post "/pair", PairController, :redeem
  end

  # Device-authenticated human surfaces.
  scope "/api", LegendWeb do
    pipe_through [:api, :device_auth]

    get "/harnesses", HarnessController, :index
    post "/harnesses/:id/setup", HarnessController, :apply_setup

    get "/runtimes", RuntimeController, :index

    get "/library/tree", LibraryController, :tree
    get "/library/file", LibraryController, :show
    put "/library/file", LibraryController, :update
    delete "/library/file", LibraryController, :delete

    get "/settings/library-path", SettingsController, :show_library_path
    put "/settings/library-path", SettingsController, :update_library_path
    delete "/settings/library-path", SettingsController, :delete_library_path

    get "/devices", DeviceController, :index
    post "/devices/pair-code", DeviceController, :create_pair_code
    delete "/devices/:id", DeviceController, :revoke
  end

  # Device-authenticated Ash JSON:API (sessions). MUST stay last under /api.
  scope "/api" do
    pipe_through [:api, :device_auth]
    forward "/", LegendWeb.AshJsonApiRouter
  end

  # SPA catch-all: anything that isn't /api or a static asset gets index.html.
  scope "/", LegendWeb do
    get "/*path", SPAController, :index
  end
end
```

> `PairController` and `DeviceController` don't exist yet (Task 6). To keep this task's tests green, the router must compile — so do Task 6's controllers immediately after, OR temporarily comment the `/pair` and `/devices*` lines and uncomment in Task 6. Prefer: implement Task 6's controller modules as empty stubs now if compilation blocks the test, then flesh out in Task 6. (The `device_auth_test` only exercises `/api/runtimes` + `/api/health`, which exist.)

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd backend && mix test test/legend_web/device_auth_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 7: Commit**

```bash
cd backend && mix format
git add backend/lib/legend_web/remote_peer.ex backend/lib/legend_web/device_auth.ex backend/lib/legend_web/router.ex backend/test/legend_web/device_auth_test.exs
git commit -m "feat(devices): DeviceAuth plug + loopback-or-token router gating"
```

---

### Task 5: Socket authentication + `connect_info`

**Files:**
- Modify: `backend/lib/legend_web/endpoint.ex` (socket `connect_info`)
- Modify: `backend/lib/legend_web/channels/user_socket.ex` (`connect/3`, `id/1`)
- Test: `backend/test/legend_web/channels/user_socket_test.exs`

**Interfaces:**
- Consumes: `LegendWeb.DeviceToken.verify/1` (Task 2), `LegendWeb.RemotePeer.loopback?/1` (Task 4), `Devices.touch_device!/1` (Task 1).
- Produces: a connected socket assigns `:device_id` (`nil` for loopback, the device id for token auth); `id/1` returns `"device:<id>"` for token devices (enables revoke-disconnect), `nil` for loopback.

- [ ] **Step 1: Write the failing test**

Create `backend/test/legend_web/channels/user_socket_test.exs`:

```elixir
defmodule LegendWeb.UserSocketTest do
  use LegendWeb.ChannelCase, async: true

  alias Legend.Core.Devices
  alias LegendWeb.{DeviceToken, UserSocket}

  defp connect_with(params, address) do
    connect(UserSocket, params, connect_info: %{peer_data: %{address: address}})
  end

  test "loopback connects without a token" do
    assert {:ok, socket} = connect_with(%{}, {127, 0, 0, 1})
    assert socket.assigns.device_id == nil
  end

  test "non-loopback without a token is refused" do
    assert :error = connect_with(%{}, {100, 64, 1, 2})
  end

  test "non-loopback with a valid token connects and assigns the device id" do
    device = Devices.create_device!(%{name: "phone", public_key: nil})
    token = DeviceToken.sign(device.id)

    assert {:ok, socket} = connect_with(%{"token" => token}, {100, 64, 1, 2})
    assert socket.assigns.device_id == device.id
  end

  test "non-loopback with a revoked token is refused" do
    device = Devices.create_device!(%{name: "phone", public_key: nil})
    token = DeviceToken.sign(device.id)
    Devices.revoke_device!(device)

    assert :error = connect_with(%{"token" => token}, {100, 64, 1, 2})
  end

  test "id is per-device for token auth, nil for loopback" do
    device = Devices.create_device!(%{name: "phone", public_key: nil})
    token = DeviceToken.sign(device.id)

    {:ok, remote} = connect_with(%{"token" => token}, {100, 64, 1, 2})
    {:ok, local} = connect_with(%{}, {127, 0, 0, 1})

    assert UserSocket.id(remote) == "device:#{device.id}"
    assert UserSocket.id(local) == nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/legend_web/channels/user_socket_test.exs`
Expected: FAIL — `connect/3` currently accepts everything and assigns no `device_id`; `connect_info` isn't wired.

- [ ] **Step 3: Wire `connect_info` on the socket**

Modify `backend/lib/legend_web/endpoint.ex` — the socket declaration:

```elixir
  socket "/socket", LegendWeb.UserSocket,
    websocket: [connect_info: [:peer_data]],
    longpoll: false
```

- [ ] **Step 4: Implement `connect/3` and `id/1`**

Modify `backend/lib/legend_web/channels/user_socket.ex` — replace `connect/3` and `id/1`:

```elixir
  alias Legend.Core.Devices
  alias LegendWeb.{DeviceToken, RemotePeer}

  @impl true
  def connect(params, socket, connect_info) do
    if loopback?(connect_info) do
      {:ok, assign(socket, :device_id, nil)}
    else
      with token when is_binary(token) <- params["token"],
           {:ok, device} <- DeviceToken.verify(token) do
        _ = Devices.touch_device!(device)
        {:ok, assign(socket, :device_id, device.id)}
      else
        _ -> :error
      end
    end
  end

  @impl true
  def id(%{assigns: %{device_id: device_id}}) when is_binary(device_id),
    do: "device:#{device_id}"

  def id(_socket), do: nil

  defp loopback?(%{peer_data: %{address: address}}), do: RemotePeer.loopback?(address)
  defp loopback?(_), do: false
```

> Delete the old `connect/3` and `id/1` clauses. Keep the `use Phoenix.Socket` and the `channel "..."` lines. The `loopback?(_)` fallback (no `peer_data`) returns false — fail closed.

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd backend && mix test test/legend_web/channels/user_socket_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 6: Verify existing channel tests still pass**

The existing `session_channel_test.exs` builds sockets without `connect_info`. Confirm those still connect (the `socket()` test helper bypasses `connect/3`, so they're unaffected):

Run: `cd backend && mix test test/legend_web/channels/`
Expected: PASS (all channel tests).

- [ ] **Step 7: Commit**

```bash
cd backend && mix format
git add backend/lib/legend_web/endpoint.ex backend/lib/legend_web/channels/user_socket.ex backend/test/legend_web/channels/user_socket_test.exs
git commit -m "feat(devices): socket auth — loopback or device token via peer_data"
```

---

### Task 6: Pairing + device-management controllers

**Files:**
- Create: `backend/lib/legend_web/controllers/pair_controller.ex`
- Create: `backend/lib/legend_web/controllers/device_controller.ex`
- Test: `backend/test/legend_web/controllers/pair_controller_test.exs`
- Test: `backend/test/legend_web/controllers/device_controller_test.exs`

**Interfaces:**
- Consumes: `Devices.{generate_pairing_code!/0, redeem_pairing_code/2, list_devices/0, get_device/1, revoke_device!/1}` (Tasks 1, 3), `LegendWeb.DeviceToken.sign/1` (Task 2).
- Produces HTTP:
  - `POST /api/pair` (public) — body `{code, name?, public_key?}` → `200 {token, device: {id, name}}` | `422 {error}`.
  - `POST /api/devices/pair-code` (device-gated; loopback in practice) → `200 {code, expires_at}`.
  - `GET /api/devices` → `200 {data: [{id, name, last_seen_at, paired_at, revoked_at}]}`.
  - `DELETE /api/devices/:id` → `200 {data: {...}}`; also disconnects the device's live sockets.

- [ ] **Step 1: Write the failing tests**

Create `backend/test/legend_web/controllers/pair_controller_test.exs`:

```elixir
defmodule LegendWeb.PairControllerTest do
  use LegendWeb.ConnCase, async: true

  alias Legend.Core.Devices

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "content-type", "application/json")}
  end

  test "redeeming a valid code mints a token, even from a non-loopback peer", %{conn: conn} do
    %{code: code} = Devices.generate_pairing_code!()

    conn =
      %{conn | remote_ip: {100, 64, 1, 2}}
      |> post("/api/pair", %{code: code, name: "iPhone"})

    assert %{"token" => token, "device" => %{"name" => "iPhone"}} = json_response(conn, 200)
    assert is_binary(token)
  end

  test "an invalid code is rejected with 422", %{conn: conn} do
    conn = post(%{conn | remote_ip: {100, 64, 1, 2}}, "/api/pair", %{code: "nope"})
    assert json_response(conn, 422)
  end
end
```

Create `backend/test/legend_web/controllers/device_controller_test.exs`:

```elixir
defmodule LegendWeb.DeviceControllerTest do
  use LegendWeb.ConnCase, async: true

  alias Legend.Core.Devices

  # All device-management endpoints are loopback by default in ConnCase
  # (build_conn remote_ip is {127,0,0,1}).
  test "generate a pairing code", %{conn: conn} do
    conn = post(conn, "/api/devices/pair-code", %{})
    assert %{"code" => code, "expires_at" => _} = json_response(conn, 200)
    assert is_binary(code)
  end

  test "list and revoke devices", %{conn: conn} do
    device = Devices.create_device!(%{name: "laptop", public_key: nil})

    list = json_response(get(conn, "/api/devices"), 200)
    assert Enum.any?(list["data"], &(&1["id"] == device.id))

    revoked = json_response(delete(conn, "/api/devices/#{device.id}"), 200)
    assert revoked["data"]["revoked_at"]
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend && mix test test/legend_web/controllers/pair_controller_test.exs test/legend_web/controllers/device_controller_test.exs`
Expected: FAIL — controllers undefined.

- [ ] **Step 3: Write `PairController`**

Create `backend/lib/legend_web/controllers/pair_controller.ex`:

```elixir
defmodule LegendWeb.PairController do
  @moduledoc """
  Public pairing redeem — the sole pre-auth human write. Validates a single-use,
  TTL-bounded code and mints a device token. Rate-limited at the router/edge in a
  later phase; single-use + short TTL bound abuse here.
  """
  use LegendWeb, :controller

  alias Legend.Core.Devices
  alias LegendWeb.DeviceToken

  def redeem(conn, %{"code" => code} = params) when is_binary(code) do
    attrs = %{name: params["name"], public_key: params["public_key"]}

    case Devices.redeem_pairing_code(code, attrs) do
      {:ok, device} ->
        json(conn, %{token: DeviceToken.sign(device.id), device: %{id: device.id, name: device.name}})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: "pairing failed: #{reason}"})
    end
  end

  def redeem(conn, _params),
    do: conn |> put_status(422) |> json(%{error: "missing required param: code"})
end
```

- [ ] **Step 4: Write `DeviceController`**

Create `backend/lib/legend_web/controllers/device_controller.ex`:

```elixir
defmodule LegendWeb.DeviceController do
  @moduledoc """
  Device management — generate pairing codes, list devices, revoke. Device-gated
  by `DeviceAuth` (loopback or a paired device); in practice driven from the
  loopback-trusted instance. Revoking disconnects the device's live sockets.
  """
  use LegendWeb, :controller

  alias Legend.Core.Devices

  def create_pair_code(conn, _params) do
    code = Devices.generate_pairing_code!()
    json(conn, %{code: code.code, expires_at: code.expires_at})
  end

  def index(conn, _params) do
    json(conn, %{data: Enum.map(Devices.list_devices(), &device_view/1)})
  end

  def revoke(conn, %{"id" => id}) do
    case Devices.get_device(id) do
      {:ok, device} ->
        revoked = Devices.revoke_device!(device)
        # Drop any live sockets this device holds.
        LegendWeb.Endpoint.broadcast("device:#{id}", "disconnect", %{})
        json(conn, %{data: device_view(revoked)})

      {:error, _} ->
        conn |> put_status(404) |> json(%{error: "device not found"})
    end
  end

  defp device_view(d) do
    %{
      id: d.id,
      name: d.name,
      paired_at: d.paired_at,
      last_seen_at: d.last_seen_at,
      revoked_at: d.revoked_at
    }
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd backend && mix test test/legend_web/controllers/pair_controller_test.exs test/legend_web/controllers/device_controller_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
cd backend && mix format
git add backend/lib/legend_web/controllers/pair_controller.ex backend/lib/legend_web/controllers/device_controller.ex backend/test/legend_web/controllers/pair_controller_test.exs backend/test/legend_web/controllers/device_controller_test.exs
git commit -m "feat(devices): pairing redeem + device management controllers"
```

---

### Task 7: `AuditEvent` resource + audit on attach/pair/revoke

**Files:**
- Create: `backend/lib/legend/core/devices/audit_event.ex`
- Modify: `backend/lib/legend/core/devices.ex` (resource + `audit!/1`, `list_audit/0`)
- Modify: `backend/lib/legend_web/controllers/pair_controller.ex` (audit a pair)
- Modify: `backend/lib/legend_web/controllers/device_controller.ex` (audit a revoke)
- Modify: `backend/lib/legend_web/channels/session_channel.ex` (audit a remote-device attach)
- Create (generated): `backend/priv/repo/migrations/*_add_audit_events.exs`
- Test: `backend/test/legend/core/audit_test.exs`
- Test: `backend/test/legend_web/channels/session_channel_audit_test.exs`

**Interfaces:**
- Consumes: `%Device{}` (Task 1); `socket.assigns.device_id` (Task 5).
- Produces:
  - `Legend.Core.Devices.audit!(%{device_id: String.t() | nil, session_id: String.t() | nil, action: String.t()}) :: %AuditEvent{}`
  - `Legend.Core.Devices.list_audit() :: [%AuditEvent{}]` (newest first)
  - Audited actions this phase: `"pair"`, `"revoke"`, `"attach"`. (Per-control-action audits — `stop`/`permission`/`prompt` — land in Phase 2 with the channel UX work; noted in the spec.)

- [ ] **Step 1: Write the failing tests**

Create `backend/test/legend/core/audit_test.exs`:

```elixir
defmodule Legend.Core.AuditTest do
  use Legend.DataCase, async: true

  alias Legend.Core.Devices
  alias Legend.Core.Devices.AuditEvent

  test "audit! records an event and list_audit returns newest first" do
    assert %AuditEvent{} = Devices.audit!(%{device_id: nil, session_id: nil, action: "pair"})
    Devices.audit!(%{device_id: nil, session_id: "s1", action: "attach"})

    actions = Devices.list_audit() |> Enum.map(& &1.action)
    assert actions == ["attach", "pair"]
  end
end
```

Create `backend/test/legend_web/channels/session_channel_audit_test.exs`:

```elixir
defmodule LegendWeb.SessionChannelAuditTest do
  use LegendWeb.ChannelCase, async: true

  alias Legend.Core.{Agents, Devices}

  test "a remote-device attach is audited; a loopback attach is not" do
    session = Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})

    # Remote device socket (device_id assigned).
    {:ok, _reply, _socket} =
      LegendWeb.UserSocket
      |> socket("device:d1", %{device_id: "d1"})
      |> subscribe_and_join(LegendWeb.SessionChannel, "session:#{session.id}")

    attach = Enum.filter(Devices.list_audit(), &(&1.action == "attach"))
    assert [%{device_id: "d1", session_id: sid}] = attach
    assert sid == session.id

    # Loopback socket (device_id nil) — no new attach audit.
    {:ok, _reply, _socket} =
      LegendWeb.UserSocket
      |> socket("local", %{device_id: nil})
      |> subscribe_and_join(LegendWeb.SessionChannel, "session:#{session.id}")

    assert length(Enum.filter(Devices.list_audit(), &(&1.action == "attach"))) == 1
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend && mix test test/legend/core/audit_test.exs test/legend_web/channels/session_channel_audit_test.exs`
Expected: FAIL — `AuditEvent` / `audit!` undefined; the channel doesn't audit yet.

- [ ] **Step 3: Write the `AuditEvent` resource**

Create `backend/lib/legend/core/devices/audit_event.ex`:

```elixir
defmodule Legend.Core.Devices.AuditEvent do
  @moduledoc """
  Append-only trail of remote interventions at control-action granularity (NOT
  raw keystrokes). `device_id` nil = a loopback/local actor.
  """
  use Ash.Resource, otp_app: :legend, domain: Legend.Core.Devices, data_layer: AshSqlite.DataLayer

  sqlite do
    table "audit_events"
    repo Legend.Repo
  end

  actions do
    defaults [:read]

    create :record do
      accept [:device_id, :session_id, :action]
    end

    read :list do
      prepare build(sort: [inserted_at: :desc])
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :device_id, :string, public?: true
    attribute :session_id, :string, public?: true
    attribute :action, :string, allow_nil?: false, public?: true
    timestamps()
  end
end
```

- [ ] **Step 4: Add the domain functions**

Modify `backend/lib/legend/core/devices.ex` — add to `resources do`:

```elixir
    resource Legend.Core.Devices.AuditEvent do
      define :audit, action: :record
      define :list_audit, action: :list
    end
```

No hand-written functions are needed — the `define`s above generate the public API.

> `define :audit, action: :record` generates `audit!/1` (takes the attrs map); `define :list_audit, action: :list` generates `list_audit/0`. Do **not** hand-write an `audit!/1` wrapper — it collides with the generated function.

- [ ] **Step 5: Generate the migration and migrate**

Run:
```bash
cd backend && mix ash.codegen add_audit_events && mix ecto.migrate
```
Expected: a migration creating `audit_events`; applies cleanly.

- [ ] **Step 6: Audit on pair, revoke, and attach**

In `backend/lib/legend_web/controllers/pair_controller.ex`, after a successful redeem (the `{:ok, device}` branch), before building the JSON:

```elixir
      {:ok, device} ->
        Devices.audit!(%{device_id: device.id, session_id: nil, action: "pair"})
        json(conn, %{token: DeviceToken.sign(device.id), device: %{id: device.id, name: device.name}})
```

In `backend/lib/legend_web/controllers/device_controller.ex`, in `revoke`'s `{:ok, device}` branch, after `revoke_device!`:

```elixir
        revoked = Devices.revoke_device!(device)
        Devices.audit!(%{device_id: id, session_id: nil, action: "revoke"})
        LegendWeb.Endpoint.broadcast("device:#{id}", "disconnect", %{})
        json(conn, %{data: device_view(revoked)})
```

In `backend/lib/legend_web/channels/session_channel.ex`, in `join/3`, audit only when a device (non-loopback) attaches. Replace the success branch:

```elixir
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
    do: Legend.Core.Devices.audit!(%{device_id: device_id, session_id: session_id, action: "attach"})
```

> `socket.assigns[:device_id]` is `nil` for loopback (Task 5) and for sockets built by the old test helper without the assign — both correctly skip the audit.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `cd backend && mix test test/legend/core/audit_test.exs test/legend_web/channels/session_channel_audit_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 8: Full suite + precommit**

Run: `cd backend && mix precommit`
Expected: compiles with no warnings, formatted, all tests pass.

- [ ] **Step 9: Commit**

```bash
git add backend/lib/legend/core/devices.ex backend/lib/legend/core/devices/audit_event.ex backend/lib/legend_web/controllers/pair_controller.ex backend/lib/legend_web/controllers/device_controller.ex backend/lib/legend_web/channels/session_channel.ex backend/priv/repo/migrations backend/priv/resource_snapshots backend/test/legend/core/audit_test.exs backend/test/legend_web/channels/session_channel_audit_test.exs
git commit -m "feat(devices): AuditEvent + audit on pair/revoke/remote-attach"
```

---

## What Phase 1 deliberately does NOT do (→ Phase 2)

- **Reachability:** the `remote_access` setting, the boot-time bind (read the setting in `application.ex` after the Repo starts — `runtime.exs` is too early), optional direct TLS, `check_origin` for the remote host, and the desktop sidecar (`main.rs`) bind. Phase 1 keeps the instance loopback-only; the auth is inert until Phase 2 opens the door — deliberately safe to land first.
- **Per-control-action audit** (`stop`/`permission`/`prompt`) — wired in Phase 2 with the channel UX.
- **All frontend:** the device-token store + socket params, the Devices management screen, the pairing redeem/QR screen, and the responsive mobile session route.
- **Rate limiting** on `POST /api/pair` beyond single-use + TTL.

## Self-Review

**Spec coverage (§ by §):**
- Trust model (loopback OR token, both choke points) → Tasks 4 (HTTP) + 5 (socket). ✔ incl. the proxy-collapse-bypass regression test.
- `Device` + reserved `public_key` → Task 1 (field) + Task 3 (populated at redeem) + Task 2 (token). ✔
- Pairing flow (code TTL, single-use, redeem mints token) → Tasks 3 + 6. ✔
- What's gated vs open (health/mcp open, pair pre-auth) → Task 4 router + tests. ✔
- Audit at control-action granularity → Task 7 (pair/revoke/attach; rest deferred, noted). ✔ (phased)
- Revocation disconnects live sockets → Task 5 (`id/1`) + Task 6 (`broadcast disconnect`). ✔
- Reachability / TLS / bind / desktop / frontend → **deferred to Phase 2** (explicit above). ✔ (scoped out)

**Placeholder scan:** No TBD/TODO; every code step has complete code. The one cross-task ordering caveat (router references Task 6 controllers) is called out with a concrete resolution in Task 4 Step 5. ✔

**Type/signature consistency:** `Devices.create_device!/1`, `get_device/1` (`{:ok|:error}`), `revoke_device!/1`, `touch_device!/1`, `generate_pairing_code!/0`, `redeem_pairing_code/2` (`{:ok, %Device{}} | {:error, :invalid|:expired|:used}`), `audit!/1`, `list_audit/0`, `DeviceToken.sign/1` + `verify/1` (`{:ok, %Device{}} | {:error, :invalid|:revoked}`), `RemotePeer.loopback?/1` — all defined in early tasks and consumed with matching arity/return in later tasks. `socket.assigns.device_id` produced in Task 5, consumed in Task 7. ✔

## Execution Handoff

Phase 1 implements the security core via TDD, one committable task at a time. Recommended: **subagent-driven-development** (fresh Opus subagent per task + review between tasks), per the user's request. Tasks 1→7 are strictly ordered by dependency; Task 4 and Task 6 are coupled (router references controllers) and should run back-to-back.
