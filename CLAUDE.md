# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Session Startup

For new sessions, avoid re-exploring the whole repository unless the task clearly requires it.

Read these files first, in order:

1. `CLAUDE.md` - repository rules, architecture overview, and coding patterns
2. `docs/engineering/feature-map.md` - which files usually change for each feature area
3. `docs/engineering/current-context.md` - active work, recent decisions, and continuation notes
4. `docs/engineering/architecture.md` - detailed data flow and subsystem responsibilities

If those files are sufficient, start implementation from the mapped files instead of doing a repo-wide search.

## Build Commands

```bash
# Build the app
xcodebuild -scheme VibeHub -configuration Release build

# Build debug version
xcodebuild -scheme VibeHub -configuration Debug build
```

The app uses XcodeGen with file system synchronization (no .xcodeproj editing needed). The project uses Swift Package Manager dependencies:
- swift-markdown (0.5.0+) - Markdown rendering
- Sparkle (2.0.0+) - Auto-update (non-App Store builds)
- mixpanel-swift (master) - Analytics (non-App Store builds)
- Clibssh (local package) - Native SSH via libssh + mbedTLS

### Release (non-App Store)

```bash
# Full pipeline: build → notarize → DMG → Sparkle → GitHub Release → appcast
./scripts/create-release.sh
```

Requires: Developer ID Application certificate, `xcrun notarytool` keychain profile "VibeHub", Sparkle EdDSA key in `.sparkle-keys/`. Releases go to `mtunique/VibeHub` (public repo). Appcast served via GitHub Pages.

## Architecture Overview

VibeHub is a macOS menu bar app (LSUIElement) that provides a Dynamic Island-style overlay for monitoring Claude Code and OpenCode CLI sessions. It communicates with the CLI via hooks installed to `~/.claude/hooks/` (Claude Code) or `~/.opencode/hooks/` (OpenCode).

### Core Data Flow

1. **HookInstaller** (`Services/Hooks/HookInstaller.swift`) - On first launch, installs `vibehub-state.py` to both `~/.claude/hooks/` and `~/.opencode/hooks/` (if they exist), and registers hook events in their respective `settings.json` files. Uses `SupportedCLI` enum to manage both.

2. **HookSocketServer** (`Services/Hooks/HookSocketServer.swift`) - Listens on Unix socket `/tmp/vibehub.sock` for events from the Python hook. Handles permission approval/denial responses.

3. **SessionStore** (`Services/State/SessionStore.swift`) - Swift **actor** that is the single source of truth for all session state. All state mutations flow through `process(_ event: SessionEvent)`.

4. **ClaudeSessionMonitor** (`Services/Session/ClaudeSessionMonitor.swift`) - `@MainActor` class that wraps SessionStore for SwiftUI binding. Publishes `instances` and `pendingInstances`.

5. **NotchViewModel** (`Core/NotchViewModel.swift`) - Manages notch open/close state and content type for SwiftUI.

6. **NotchView** (`UI/Views/NotchView.swift`) - Main SwiftUI view that renders the Dynamic Island overlay with accurate notch shape geometry.

### Key Models

- **SessionState** (`Models/SessionState.swift`) - Unified state for a Claude session (phase, chatItems, toolTracker, subagentState)
- **SessionPhase** (`Models/SessionPhase.swift`) - State machine: `idle`, `processing`, `compacting`, `waitingForInput`, `waitingForApproval`
- **ChatHistoryItem** (`Models/ChatMessage.swift`) - Individual chat message or tool call

### Session Phase State Machine

```
idle <-> processing <-> compacting
                   <-> waitingForInput
                   <-> waitingForApproval
```

### UI Structure

- **NotchView** - Main Dynamic Island container with accurate MacBook notch shape
- **NotchMenuView** - Settings menu (screen selection, sound picker)
- **ClaudeInstancesView** - List of active Claude sessions when notch is expanded
- **ChatView** - Full conversation history with markdown rendering

### Window Management

- **WindowManager** - Creates/manages the `NotchWindowController` (NSWindow subclass)
- **ScreenSelector** - Handles multi-monitor setup, detects physical notch
- **NotchGeometry** - Calculates notch position and opened size based on screen

### Hook Events

The Python hook (`Resources/vibehub-state.py`) sends these events via socket:
- `UserPromptSubmit` - User sent a message (Claude now processing)
- `PreToolUse` - Tool about to execute
- `PostToolUse` - Tool completed
- `PermissionRequest` - Tool needs approval (blocks until response)
- `Notification` - Claude sent a notification
- `Stop`, `SessionStart`, `SessionEnd` - Session lifecycle
- `PreCompact` - Before conversation compaction

### Notification Behavior

The notch proactively appears in these scenarios:
- **New permission request** - When a tool needs approval (opens if terminal not visible)
- **Claude finishes processing** - When Claude enters `waitingForInput` state with a result, the notch expands automatically to show the output

When Claude finishes, the notch:
1. Expands to show the result
2. Plays a notification sound (if configured in settings)
3. Bounces briefly to draw attention
4. Shows a checkmark indicator for 30 seconds

### Tool Approval Flow

1. Hook detects `PermissionRequest` → sends to app via socket
2. App shows expanded notch with Approve/Deny buttons
3. User clicks button → app sends response over socket
4. Hook receives response and proceeds or denies

### Remote SSH Monitoring

- **RemoteManager** (`Services/Remote/RemoteManager.swift`) - Manages remote host connections, reconnection, install tasks. Exposes `exec(hostId:command:)` for running commands via native SSH.
- **NativeSSHForwarder** (`Services/Remote/NativeSSH/NativeSSHForwarder.swift`) - libssh-based SSH tunnel. Runs on a dedicated thread. Supports reverse TCP forwarding and command execution via an exec queue (commands enqueued from any thread, drained in the forward loop).
- **RemoteInstaller** (`Services/Remote/RemoteInstaller.swift`) - Installs hooks on remote hosts via SSH. Also provides `runSSH`/`runSSHResult` for process-based SSH fallback.
- **TerminalActivator** (`Services/Window/TerminalActivator.swift`) - Activates terminal windows for sessions. For remote sessions with multiple SSH connections to the same host, queries the remote via `RemoteManager.exec` to match the correct local SSH tab by TCP source port.

### Licensing (non-App Store only)

All licensing code is behind `#if !APP_STORE`. Uses LemonSqueezy API.

- **LemonSqueezyAPIClient** (`Services/License/LemonSqueezyAPIClient.swift`) - Validate/activate/deactivate via `api.lemonsqueezy.com`. Form-encoded requests, JSON responses.
- **LicenseManager** (`Services/License/LicenseManager.swift`) - Orchestrates validation at startup, activation, deactivation. 7-day trial via Keychain. 7-day offline grace period.
- **KeychainStore** (`Services/License/KeychainStore.swift`) - Persists license cache and trial data in macOS Keychain.
- Checkout URL in `LemonSqueezyAPIClient.checkoutURL`.

### File Watching

- **AgentFileWatcher** - Monitors `.claude/projects/*/agent/*.jsonl` for subagent conversation updates
- **JSONLInterruptWatcher** - Detects when Claude is interrupted mid-tool

## Code Patterns

- `@MainActor` for all UI-bound classes (ClaudeSessionMonitor, NotchViewModel, RemoteManager, LicenseManager)
- Swift **actor** for thread-safe SessionStore and TerminalActivator
- `CurrentValueSubject` with `receive(on: DispatchQueue.main)` for UI binding
- `matchedGeometryEffect` for smooth notch animations
- SwiftUI + AppKit interop via `NSApplicationDelegateAdaptor`
- NativeSSHForwarder runs libssh on a dedicated `Thread` — all `ssh_*` calls stay on that thread; cross-thread communication via `NSLock`-guarded exec queue with `withCheckedContinuation`
- Conditional compilation: `#if !APP_STORE` guards licensing, Sparkle updates, and Mixpanel analytics
- `NotchWindowController.hasBooted` static flag prevents boot animation on screen-change window recreation
- Notch auto-expansion checks `TerminalActivator.isSessionTerminalFocused` before opening (avoids popping when terminal is in foreground)
