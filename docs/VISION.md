# Legend — Vision

**Status:** living document. Every spec in `docs/superpowers/specs/` should be checkable against this document; when the vision changes, change this file first.

## What Legend is

Legend is an orchestrator platform for AI agents: one interface for Claude Code, Hermes, OpenClaw, and whatever harnesses come next.

Legend is not a tool. It is a conductor. An orchestrator:

- **Aligns context** across agents, tools, and memory so everyone works toward the same goal.
- **Manages state** — tracks who, what, and when, so nothing gets lost.
- **Enables handoff fluidity** — when one agent finishes, the baton passes seamlessly to the next.
- **Remains human-centered** — the user is always the lead conductor; agents are instruments.

This framing is the priority filter for all work: *is this infrastructure for orchestration, or a nice-to-have add-on?* Infrastructure ships first.

## Product principles

1. **The human is the conductor.** Humans are first-class participants in every agent conversation — able to intervene, re-assign, or redirect any agent at any point. Human-in-the-loop is structural, not bolted on.
2. **Local-first.** Core functionality — sessions, agents, memory, tasks — works fully offline on local hardware. Cloud is optional and explicit: "your data never leaves your machine unless you say so."
3. **Data sovereignty.** Opt-in, end-to-end encrypted sync to a Swiss-hosted cloud; selective sync for granular control. Positioning for privacy-conscious users and compliance-conscious KMUs.
4. **Composable via plugins.** Harnesses, runtimes, tools, integrations, and UI panels are extension points — like VS Code or Obsidian extensions. The platform core stays small; capability arrives as plugins.
5. **Terminal is the universal fallback; rich UI is progressive enhancement.** Any agent with a CLI works in Legend through the embedded terminal. Agents that speak a known protocol (ACP or a Legend-native harness) get a full interactive UI on top. The layers are additive — the terminal stays available as an escape hatch.
6. **Open source.** Public codebase: auditable (trust), contributable (the plugin ecosystem's entry point), and a differentiator against closed competitors.
7. **Pay as you go.** Usage-based pricing (tokens, compute, storage) instead of seat fees; pairs with self-hosted and bring-your-own-model options.

## The architecture spine

Realized incrementally, starting with the agent sessions PoC (`docs/superpowers/specs/2026-06-11-agent-sessions-poc-design.md`). Phoenix is the proxy and coordination layer throughout: channels multiplex terminal sessions, agent events, and signals over one WebSocket; the BEAM holds thousands of concurrent session processes; channel join/auth is the access-control point.

**Sessions** are the unit of agent work: one harness (which agent) composed with one runtime (where it runs), addressable, attachable, and persistent across UI disconnects.

**The harness axis** — *which agent, and how it talks:*

| Kind | Transport | Experience |
|---|---|---|
| `:terminal` | PTY byte stream → xterm.js | Universal — any CLI works |
| `:acp` | subprocess, JSON-RPC over pipes (Agent Client Protocol) | Rich UI: structured prompts, tool calls, diffs, permissions |
| `:native` | in-BEAM agent (Jido + jido_ai + req_llm), no subprocess | Rich UI: structured chat; Legend hosts the agent itself |

**The runtime axis** — *where agents execute:* local PTY on the user's machine (desktop sidecar), Docker containers, Fly Machines / hosted sandboxes, and reverse-tunneled remote machines — all behind one behaviour, so cloud execution is an adapter, not a rewrite. Legend is the UI for the whole fleet: launch, monitor, and interact with long-running sandboxed agents, each with its own workspace, tools, and memory.

**Agent-to-agent communication** rides a signal bus (PubSub envelopes on room topics). Rooms hold sessions *and humans* as members. Message delivery into an agent: native → direct, ACP → structured prompt, terminal → formatted PTY injection. Structured output from an agent, by preference: native > ACP session updates > Legend-provided MCP tools the agent calls explicitly (`send_message`, `handoff`, `read_messages`) > human relay. Scrollback parsing is rejected.

**Federation:** a user runs multiple Legend instances — local (desktop) and cloud — and continues the *same* sessions from either. The local instance pairs with the cloud over an outbound reverse tunnel (no inbound ports) and registers its sessions; the cloud UI proxies channel traffic to the owning instance. Federation is also where authentication becomes mandatory.

**The windowing core** realizes principle 4 ("UI panels are extension points") for the frontend. Tiling is the windowing core of the app: every view is a tile in a layout, not a route. *Surfaces* — `session`, `file`, `messages` today, calendar/email later — are the concrete form of the panel-as-extension-point idea: each is a `(kind, params)` binding resolved through a registry to a component, so a new panel type is a registry entry, not a new page. *Spaces* are named tiling workspaces the user arranges (and, later, an agent arranges) — an auto Sessions space, a Library space, and user-created custom spaces. *Sources* are the input side of the same idea: a persistent dock of pluggable `DockSource` panels (Sessions, Files today) you pull content from — click or drag a dock item into the workspace to tile it — so a new content source is a registry entry just as a new surface is. The launcher's `openSurface(kind, params)` call is the seam an agent will eventually use to arrange the human's UI on its own, the same way it spawns sessions and sends messages today.

## Concept map

The long-term concepts, organized by layer. Items here are direction, not commitments with dates.

### 1. Orchestration core

- **Multiplayer / multi-agent collaboration:** invite specialized agents (Researcher, Coder, Compliance Officer) into one chat thread; agent-to-agent handoffs within shared context; a shared workspace and persistent memory for the collaborative session; workgroups — persistent agent teams working toward shared goals.
- **Session infrastructure** (PoC, in progress): harness/runtime plugin seams, embedded terminal, reattach, lifecycle management.

### 2. Agent capabilities

- **AI writes skills:** users describe a capability; Legend scaffolds the skill definition (tool bundle + instructions), tests it, and registers it. The skill library grows without manual dev work.
- **Self-maintaining AI (the Hermes model):** agents that write their own skills and scripts and store them retrievably — improving their own tooling as a side effect of doing tasks. Open questions to resolve when this layer is designed: when to write vs. reuse an existing script; what the indexing/retrieval layer for self-authored artefacts looks like; how to prevent skill/script sprawl.
- **AI stores reusable artefacts:** agents automatically persist reusable outputs (prompts, snippets, templates, analyses) into a shared artefact store — institutional memory that compounds.

### 3. Resource infrastructure

- **Model registry:** register and configure LLM endpoints — local (Ollama, LM Studio), private (Infomaniak, OpenAI-compatible), or cloud — and route tasks by capability, cost, or data residency. `req_llm`'s unified provider interface is the natural substrate.
- **File storage layer:** a unified, agent-accessible store with pluggable backends (local filesystem, S3-compatible, Google Drive). Sandboxes can serve as primary workspaces. The non-negotiable property: **common storage across agents** — a script Claude Code writes must be retrievable by Hermes. Without this, multi-agent handoffs aren't real.

### 4. Platform & product

- **Desktop app:** Tauri shell with the backend as a bundled sidecar — shipped in the scaffold. Enables global hotkeys, system tray, local files, notifications.
- **Hotkey quick capture:** a global hotkey (e.g. Cmd+Shift+Space) opens a small overlay to dump raw thoughts into a Drafts/Inbox — lightweight, fire-and-forget.
- **Cloud sync:** opt-in E2E-encrypted sync between instances via the Swiss-hosted backend; selective per-domain sync (e.g. brains but not email).
- **Local email client & calendar:** privacy-first, local storage, local AI processing — IMAP/CalDAV (possibly wrapping Mailcow/Roundcube). Connects to the email-as-first-service strategy for compliance-conscious KMUs.
- **Pay as you go:** metering and billing for tokens/compute/storage.

### 5. Ecosystem

- **Plugin system as a product:** today's plugin seams are internal (behaviour registries in config). The public story — packaging, discovery, manifests, third-party distribution — gets designed once internal plugins have proven the contracts.
- **Open source release:** public repo, contribution guidelines, plugin SDK as the community's primary contribution vector.

## Sequencing

1. **Scaffold** — done: Phoenix/Ash/SQLite backend, SvelteKit SPA, Tauri sidecar desktop app, dual releases.
2. **Agent sessions PoC** — spec approved: two terminal harnesses (Claude Code, Hermes), local PTY runtime, embedded terminal with reattach.
3. **Next candidates, in rough order of leverage:**
   - **Native harness** (Jido chat agent) — proves the plugin model with a different *kind*, gives Legend a built-in agent with zero external dependencies.
   - **ACP harness + rich UI** — structured rendering for Claude Code (via `claude-code-acp`) and other ACP agents.
   - **Rooms / multi-agent chat** — the orchestration story proper, built on the session substrate and signal bus.
   - **Cloud runtime + federation** — sessions in sandboxes; local↔cloud instance pairing (auth arrives here).
4. Resource infrastructure (models, files, artefacts) lands when the layer above demands it — file storage at the latest with rooms, the model registry with the native harness's growth.

## Alignment test for new work

Before specifying a feature, answer:

1. Is this **infrastructure for orchestration** (context alignment, state, handoffs, human control) or an add-on? Infrastructure wins.
2. Does it keep the **human as conductor**?
3. Does it work **local-first**, with cloud as an explicit opt-in?
4. Is it shaped as (or extendable by) a **plugin** rather than hardcoded into the core?
5. Does it preserve the **terminal-fallback / rich-UI-enhancement** layering?

If a proposal fails one of these and still seems right, the answer may be to update this document — explicitly, not silently.
