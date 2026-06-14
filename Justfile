# legend — dev & build orchestration

default:
    @just --list

# Install all dependencies
setup:
    cd backend && mix setup
    cd frontend && bun install
    cd desktop && bun install

# Backend + frontend dev servers (web dev: http://localhost:5173)
dev:
    #!/usr/bin/env bash
    set -euo pipefail
    trap 'kill 0' EXIT
    (cd backend && mix phx.server) &
    (cd frontend && bun run dev) &
    wait

# Backend + Tauri dev shell (Tauri starts the frontend dev server itself)
dev-desktop:
    #!/usr/bin/env bash
    set -euo pipefail
    trap 'kill 0' EXIT
    (cd backend && mix phx.server) &
    (cd desktop && bun tauri dev) &
    wait

# Build the SPA, bake it into Phoenix, assemble the web release
build:
    cd frontend && bun run build
    rm -rf backend/priv/static/_app backend/priv/static/index.html
    cp -R frontend/build/. backend/priv/static/
    backend/scripts/build-release.sh legend

# Package the backend as the desktop sidecar binary (auto-provisions zig 0.15.2)
package-backend:
    #!/usr/bin/env bash
    set -euo pipefail
    backend/scripts/build-release.sh legend_desktop
    triple=$(rustc -vV | sed -n 's/host: //p')
    mkdir -p desktop/src-tauri/binaries
    cp backend/burrito_out/legend_desktop_macos_arm "desktop/src-tauri/binaries/legend-server-${triple}"

# Full desktop bundle
desktop-bundle: package-backend
    cd desktop && bun tauri build

# Cross-compile the in-sprite reverse-tunnel bridge (static x86_64 musl)
build-bridge:
    rustup target add x86_64-unknown-linux-musl
    cd bridge && cargo zigbuild --release --target x86_64-unknown-linux-musl
    mkdir -p backend/priv/tunnel
    cp bridge/target/x86_64-unknown-linux-musl/release/legend-bridge backend/priv/tunnel/legend-bridge-x86_64-linux
    @file backend/priv/tunnel/legend-bridge-x86_64-linux

# Run all checks
test:
    cd backend && mix test
    cd frontend && bun run check
