# Current Context

This file is intentionally short-lived and should be updated after meaningful feature work.

## How To Use It

- Keep this document brief and practical.
- Prefer current decisions and continuation notes over historical narrative.
- Delete stale bullets rather than letting the file grow indefinitely.

## Stable Mental Model

- `SessionStore` is the canonical state owner.
- UI-bound coordination lives on `@MainActor`.
- Notch behavior is a combination of state transitions, terminal visibility, and UI presentation.
- Local CLI, OpenCode, and remote flows converge into the same visible session model.

## Current Priorities

- Preserve a fast startup path for new coding sessions by keeping engineering docs accurate.
- Keep CLI integration details aligned across `CLAUDE.md` and code.
- Prefer narrow changes in the owning subsystem before making cross-cutting edits.

## Continuation Notes

- When starting a new task, read `feature-map.md` before repo-wide search.
- If you finish a feature that changes ownership or edit patterns, update `feature-map.md`.
- If you finish a feature that changes active assumptions, update this file in the same patch.

## Known Documentation Debt

- Some top-level docs still reflect earlier branding and integration wording.
- Product-facing docs in `docs/` are separate from engineering-facing docs in `docs/engineering/`.
- If architecture changes, update the engineering docs first so future sessions inherit the right map.
