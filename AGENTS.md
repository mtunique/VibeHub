# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Build Commands

```bash
# Build the app
xcodebuild -scheme VibeHub -configuration Release build

# Build debug version
xcodebuild -scheme VibeHub -configuration Debug build
```

The app uses XcodeGen with file system synchronization (no .xcodeproj editing needed). The project uses Swift Package Manager dependencies:
- swift-markdown (0.5.0+) - Markdown rendering
- Sparkle (2.0.0+) - Auto-update
- mixpanel-swift (master) - Analytics

## Architecture Overview

Codex Island is a macOS menu bar app (LSUIElement) that provides a Dynamic Island-style overlay for monitoring Codex and OpenCode CLI sessions. It communicates with the CLI via hooks installed to `~/.Codex/hooks/` (Codex) or `~/.opencode/hooks/` (OpenCode).

### Core Data Flow

1. **HookInstaller** (`Services/Hooks/HookInstaller.swift`) - On first launch, installs `Codex-island-state.py` to both `~/.Codex/hooks/` and `~/.opencode/hooks/` (if they exist), and registers hook events in their respective `settings.json` files. Uses `SupportedCLI` enum to manage both.

2. **HookSocketServer** (`Services/Hooks/HookSocketServer.swift`) - Listens on Unix socket `/tmp/Codex-island.sock` for events from the Python hook. Handles permission approval/denial responses.

3. **SessionStore** (`Services/State/SessionStore.swift`) - Swift **actor** that is the single source of truth for all session state. All state mutations flow through `process(_ event: SessionEvent)`.

4. **ClaudeSessionMonitor** (`Services/Session/ClaudeSessionMonitor.swift`) - `@MainActor` class that wraps SessionStore for SwiftUI binding. Publishes `instances` and `pendingInstances`.

5. **NotchViewModel** (`Core/NotchViewModel.swift`) - Manages notch open/close state and content type for SwiftUI.

6. **NotchView** (`UI/Views/NotchView.swift`) - Main SwiftUI view that renders the Dynamic Island overlay with accurate notch shape geometry.

### Key Models

- **SessionState** (`Models/SessionState.swift`) - Unified state for a Codex session (phase, chatItems, toolTracker, subagentState)
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
- **ClaudeInstancesView** - List of active Codex sessions when notch is expanded
- **ChatView** - Full conversation history with markdown rendering

### Window Management

- **WindowManager** - Creates/manages the `NotchWindowController` (NSWindow subclass)
- **ScreenSelector** - Handles multi-monitor setup, detects physical notch
- **NotchGeometry** - Calculates notch position and opened size based on screen

### Hook Events

The Python hook (`Resources/Codex-island-state.py`) sends these events via socket:
- `UserPromptSubmit` - User sent a message (Codex now processing)
- `PreToolUse` - Tool about to execute
- `PostToolUse` - Tool completed
- `PermissionRequest` - Tool needs approval (blocks until response)
- `Notification` - Codex sent a notification
- `Stop`, `SessionStart`, `SessionEnd` - Session lifecycle
- `PreCompact` - Before conversation compaction

### Notification Behavior

The notch proactively appears in these scenarios:
- **New permission request** - When a tool needs approval (opens if terminal not visible)
- **Codex finishes processing** - When Codex enters `waitingForInput` state with a result, the notch expands automatically to show the output

When Codex finishes, the notch:
1. Expands to show the result
2. Plays a notification sound (if configured in settings)
3. Bounces briefly to draw attention
4. Shows a checkmark indicator for 30 seconds

### Tool Approval Flow

1. Hook detects `PermissionRequest` → sends to app via socket
2. App shows expanded notch with Approve/Deny buttons
3. User clicks button → app sends response over socket
4. Hook receives response and proceeds or denies

### File Watching

- **AgentFileWatcher** - Monitors `.Codex/projects/*/agent/*.jsonl` for subagent conversation updates
- **JSONLInterruptWatcher** - Detects when Codex is interrupted mid-tool

## Code Patterns

- `@MainActor` for all UI-bound classes (ClaudeSessionMonitor, NotchViewModel)
- Swift **actor** for thread-safe SessionStore (no actor isolation issues since UI uses MainActor)
- `CurrentValueSubject` with `receive(on: DispatchQueue.main)` for UI binding
- `matchedGeometryEffect` for smooth notch animations
- SwiftUI + AppKit interop via `NSApplicationDelegateAdaptor`
