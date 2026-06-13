# legend-bridge

A loopback-only reverse-tunnel bridge that runs inside a Sprites microVM.

## What it does

Two TCP listeners (both bound once at startup — never re-bound on reconnect):

| Listener | Default port | Purpose |
|----------|-------------|---------|
| Control  | `127.0.0.1:9000` | The Legend backend connects here; this single connection is the mux carrier. |
| Data     | `127.0.0.1:7777` | The in-sprite agent's HTTP client connects here; each connection becomes one mux stream. |

Bytes from a data connection are wrapped in `DATA` frames and sent over the control carrier. `DATA` frames arriving from the carrier are forwarded to the matching data socket. `OPEN` announces a new stream; `CLOSE` tears one down.

## Mux wire format

Big-endian, no alignment padding — matches `backend/lib/legend/core/tunnel/mux.ex` exactly:

```
type:u8  stream_id:u32  length:u32  payload:[length bytes]
```

| Type | Value | Payload |
|------|-------|---------|
| OPEN   | 1 | none |
| DATA   | 2 | raw bytes |
| CLOSE  | 3 | none |
| WINDOW | 4 | credit:u32 (big-endian) |

`INITIAL_WINDOW = 262144`. v1: WINDOW frames are decoded but treated as no-ops; backpressure relies on bounded `mpsc` channels.

## Build — native (development / CI)

```sh
cd bridge
cargo build --release
# binary: bridge/target/release/legend-bridge
```

## Build — musl static (for Linux microVMs) — DEFERRED

Requires `rustup` and the musl target. This cannot be built in the current environment (no `rustup` installed).

**IMPORTANT:** confirm the sprite microVM CPU architecture first (run `uname -m` inside a sprite shell). Use `x86_64` or `aarch64` accordingly.

### x86_64 (most common)

```sh
rustup target add x86_64-unknown-linux-musl
cd bridge
cargo build --release --target x86_64-unknown-linux-musl
cp target/x86_64-unknown-linux-musl/release/legend-bridge \
   ../backend/priv/tunnel/legend-bridge-x86_64-linux
```

### aarch64 (ARM microVMs)

```sh
rustup target add aarch64-unknown-linux-musl
# A C cross-linker is also needed; on macOS:
brew install FiloSottile/musl-cross/musl-cross
CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=aarch64-linux-musl-gcc \
cargo build --release --target aarch64-unknown-linux-musl
cp target/aarch64-unknown-linux-musl/release/legend-bridge \
   ../backend/priv/tunnel/legend-bridge-aarch64-linux
```

After copying, update the Elixir `SpriteTunnel` provisioner to upload the correct artifact to the sprite.

## Runtime verification (DEFERRED)

Requires a live sprite and `SPRITES_TOKEN`. End-to-end test:

1. Start bridge inside sprite: `./legend-bridge`
2. From backend: open control connection to sprite-proxied `127.0.0.1:9000`
3. From inside sprite: `curl http://127.0.0.1:7777/` — should reach the backend via mux
