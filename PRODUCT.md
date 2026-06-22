# Product

## Register

product

## Users

Developers and power users who run several AI coding agents (Claude Code, Hermes, OpenClaw, and whatever CLI harnesses come next) in parallel. They live in keyboard-driven professional tools, work at high information density, and expect the conventions of Linear / Zed / Raycast to simply work — no hand-holding, no ceremony.

Their context is a focused work session juggling multiple long-running agents at once: launching them, watching what they do, redirecting or re-assigning when needed, and handing the baton between them. The job to be done is to **orchestrate a fleet of agents from one place without losing track of who is doing what** — able to intervene at any moment, keeping everything local and auditable.

## Product Purpose

Legend is an orchestrator platform for AI agents — one interface for Claude Code, Hermes, OpenClaw, and future harnesses. It is a conductor, not a tool: it aligns context across agents, tracks state (who, what, when), enables fluid handoffs, and keeps the human in the lead. **Sessions** (one harness × one runtime) are the unit of work; the embedded terminal is the universal fallback, and rich UI (ACP / native harnesses) is progressive enhancement layered on top. Local-first and open-source by default, with opt-in, end-to-end-encrypted cloud sync.

Success looks like: a user runs, monitors, and coordinates many agents across local and cloud machines from one calm, fast surface — and trusts everything they see, because nothing is hidden and their data never leaves the machine unless they say so.

## Brand Personality

**Precise · Calm · Technical.** An instrument, not a toy. The voice is exact and unhurried; it speaks to people who already know what they're doing and never over-explains. Defaults are opinionated and plainly stated — trust is earned through restraint and transparency, not persuasion.

Three experiential goals the surface optimizes for:

- **Fast & precise** — keyboard-first, zero perceived latency, dense but legible.
- **Trustworthy & transparent** — auditable, local-first made visible, nothing hidden.
- **Quietly powerful** — deep capability that stays calm on the surface; restraint over spectacle. (Notably *not* theatrical "command-center" drama — the power is real, the presentation is composed.)

## Anti-references

Legend must never read as any of these:

- **Generic SaaS dashboard** — gradient hero-metrics, identical card grids, an uppercase tracked eyebrow above every section, marketing-y chrome. The AI-slop default.
- **Playful consumer AI chat** — bubbly rounded message bubbles, emoji, pastel gradients, mascots. Too soft and toy-like for a professional orchestration tool.
- **Neon "AI / crypto" hype** — glassmorphism, glow, drenched gradients, sci-fi HUD theatrics. Spectacle is the opposite of trustworthy.
- **Cluttered enterprise IDE** — toolbar overload, busy chrome, every feature surfaced at once. Density without hierarchy.

Positive references (the feel to aim for): **Linear** — calm precision, opinionated defaults, hairline restraint, motion that only ever conveys state. **Zed** — a native-feeling developer tool: fast, dark, dense, zero-latency, built for people who live inside it.

## Design Principles

1. **The tool disappears into the task.** Earned familiarity over novelty — match the conventions of best-in-class pro tools and never reinvent a standard affordance for flavor. The bar: a fluent user sits down and trusts the interface instantly, never pausing at a subtly-off control.
2. **The human is the conductor.** Human-in-the-loop is structural, not bolted on. Any agent can be observed, interrupted, redirected, or re-assigned at any moment; the UI always keeps the human in the lead.
3. **Restraint over spectacle.** Quietly powerful. Density *with* hierarchy, never density as clutter. No decoration competes with the work — color and motion are reserved for meaning (state, selection, identity), never ornament.
4. **Transparency earns trust.** Show what every agent did. Local-first and open-source made visible — the user can see and verify; nothing is hidden. Trust is a feature, not a tagline.
5. **Terminal is the floor; rich UI is enhancement.** Every layer is additive: any CLI agent works through the embedded terminal, and richer protocols (ACP, native) layer structured UI on top without ever removing the escape hatch.

## Accessibility & Inclusion

Committed bar:

- **WCAG AA contrast** against the dark violet surface ramp — body text ≥ 4.5:1, large text ≥ 3:1; placeholder and muted text held to the same 4.5:1 (no light-gray-for-elegance). Verify against `--bg-app` / `--bg-shell`, not pure black.
- **Full keyboard navigation** — every action reachable and operable from the keyboard with a visible focus ring (the accent `--ring`), matching the keyboard-first power-user goal.

Practiced from the design ethos (not formal targets, but cheap to uphold given the system): motion is already state-only and minimal, so `prefers-reduced-motion` alternatives are provided wherever motion exists; status and agent-identity colors should pair hue with an icon, shape, or label so meaning survives color-blindness. Dark-only is intentional (see [docs/DESIGN_SYSTEM.md](docs/DESIGN_SYSTEM.md)) — there is no light theme and no runtime switcher.
