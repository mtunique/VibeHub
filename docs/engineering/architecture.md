# Engineering Architecture

This document is for coding agents and contributors who need a fast, implementation-oriented map of the app.

## Primary Goal

Vibe Hub is a macOS menu bar app that surfaces live Claude Code and OpenCode session activity in a Dynamic Island-style overlay. The app reacts to hook events, stores normalized session state, and renders that state through SwiftUI and AppKit window management.

## First Files To Read

- `VibeHub/Services/State/SessionStore.swift`
- `VibeHub/Models/SessionEvent.swift`
- `VibeHub/Core/NotchViewModel.swift`
- `VibeHub/UI/Views/NotchView.swift`
- `VibeHub/Services/Hooks/HookSocketServer.swift`

Those files cover the central event flow from incoming CLI activity to visible notch state.

## Runtime Flow

1. CLI-side integrations send events into the app.
2. Socket and plugin layers normalize those events into `SessionEvent`.
3. `SessionStore` processes the events and updates canonical `SessionState`.
4. `ClaudeSessionMonitor` publishes store snapshots for SwiftUI.
5. `NotchViewModel` decides what the notch should show and when it should open.
6. SwiftUI views render active sessions, approval requests, chat history, and results.

## Major Subsystems

### App and Window Shell

- `VibeHub/App/`
- `VibeHub/UI/Window/`

Responsible for app startup, menu bar integration, NSWindow lifecycle, onboarding window flow, and attaching the notch UI to the correct screen.

### Core Notch Behavior

- `VibeHub/Core/NotchViewModel.swift`
- `VibeHub/Core/NotchActivityCoordinator.swift`
- `VibeHub/Core/NotchGeometry.swift`
- `VibeHub/Core/ScreenSelector.swift`
- `VibeHub/Core/Settings.swift`

Contains notch geometry, selection of display target, persisted settings, and high-level state that determines when the notch is collapsed, expanded, or drawing attention.

### Event and Session Models

- `VibeHub/Models/SessionEvent.swift`
- `VibeHub/Models/SessionState.swift`
- `VibeHub/Models/SessionPhase.swift`
- `VibeHub/Models/ChatMessage.swift`

Defines the event contract, session lifecycle, and the shape of data rendered in the UI.

### State Processing

- `VibeHub/Services/State/SessionStore.swift`
- `VibeHub/Services/State/ToolEventProcessor.swift`
- `VibeHub/Services/State/FileSyncScheduler.swift`

This is the canonical state pipeline. If behavior looks wrong in the UI, check whether the store state is wrong before changing view code.

### Local CLI Integration

- `VibeHub/Services/Hooks/HookInstaller.swift`
- `VibeHub/Services/Hooks/HookSocketServer.swift`
- `VibeHub/Services/Hooks/HookSocketRouter.swift`
- `VibeHub/Resources/`

Handles installation of local integrations and receipt of runtime events from Claude Code or Codex-style hooks.

### OpenCode Integration

- `VibeHub/Services/OpenCode/OpenCodePluginInstaller.swift`

Owns OpenCode-specific installation and compatibility concerns. Use this area when the feature is CLI-specific rather than session-state-specific.

### Session File Watching

- `VibeHub/Services/Session/ClaudeSessionMonitor.swift`
- `VibeHub/Services/Session/AgentFileWatcher.swift`
- `VibeHub/Services/Session/ConversationParser.swift`
- `VibeHub/Services/Session/JSONLInterruptWatcher.swift`

Bridges state from on-disk CLI artifacts into the app, especially for subagent activity and conversation updates.

### Tool Approval and Terminal Actions

- `VibeHub/Services/Tmux/`
- `VibeHub/Services/Window/`
- `VibeHub/Utilities/TerminalVisibilityDetector.swift`

Used when approval flow needs to route back into tmux or when the app decides whether it should interrupt the user with notch UI.

### Remote Support

- `VibeHub/Services/Remote/`
- `VibeHub/Services/Shared/UnixSocketClient.swift`
- `VibeHub/Services/Shared/ProcessExecutor.swift`

Supports remote hosts, SSH forwarding, install/report flows, and remote socket connectivity.

### UI Rendering

- `VibeHub/UI/Views/`
- `VibeHub/UI/Components/`

Pure presentation and interaction code. Prefer changing model or view-model behavior first when a UI bug is driven by incorrect state.

## Change Heuristics

- If a new event type or lifecycle state is involved, start in `Models/` and `Services/State/`.
- If the data is correct but the notch opens or closes at the wrong time, start in `Core/`.
- If the notch content is wrong but the state looks right, start in `UI/Views/`.
- If the issue only happens for Claude Code, hooks, or OpenCode, start in the integration service rather than UI.
- If a bug only reproduces for remote sessions, inspect `Services/Remote/` before changing shared state logic.

## High-Value Invariants

- `SessionStore` is the source of truth for session state.
- UI-facing observable classes stay on `@MainActor`.
- Session phase changes should stay consistent with the lifecycle documented in `CLAUDE.md`.
- Approval flows usually touch both event intake and the visible notch state. Avoid fixing one side only.

## When To Re-Explore

Repo-wide exploration is justified when:

- the task introduces a brand-new subsystem
- the mapped files do not explain current behavior
- naming drift suggests the architecture document is stale
- the bug crosses multiple feature areas and the primary owner is unclear

Otherwise, use `feature-map.md` and start from the narrowest relevant files.
