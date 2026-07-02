# Zetty

A GUI terminal **multiplexer** for developers, built on
[libghostty](https://github.com/ghostty-org/ghostty) (Ghostty's embeddable terminal
core) with a **Swift** application layer.

Zetty organizes work around **pinnable projects/directories**, each holding multiple
terminal **sessions** with **tabs and splits** — and it natively **detects AI coding
agents** (Claude Code, Codex, opencode, Aider, Gemini, hermes) running in those sessions,
surfacing their status (running / idle / needs-attention) in the sidebar.

**Platforms:** macOS first; Linux later.

## Core principle

We build the multiplexer shell, not the terminal. Full libghostty provides VT emulation,
GPU rendering, font/text shaping, surfaces, and both Kitty protocols (keyboard + graphics)
for free.

## Documentation

- [Product Requirements & Design](docs/plans/2026-06-25-quertty-prd.md)

## Status

Early design / pre-implementation. See the PRD for the roadmap.
