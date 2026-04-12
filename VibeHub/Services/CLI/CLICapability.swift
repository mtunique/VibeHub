//
//  CLICapability.swift
//  VibeHub
//
//  Historical storage and per-CLI capability matrix. Consumed by
//  SessionStore (history dispatch), SessionEvent (shouldSyncFile),
//  ChatView (canSendInput), and CLIInstaller (supportsRemoteInstall).
//

import Foundation

/// Where a CLI's conversation history lives — drives history loading in
/// `SessionStore.loadHistoryFromFile`.
enum HistoryKind: Sendable {
    /// Claude Code and its forks. Loaded via `ConversationParser` from
    /// `<configDir>/projects/<cwd>/<sessionId>.jsonl`.
    case jsonl
    /// OpenCode — loaded via `OpenCodeDBParser` from `~/.local/share/opencode/opencode.db`.
    case sqlite
    /// Codex — loaded via `CodexRolloutParser` from `~/.codex/sessions/YYYY/MM/DD/rollout-*`.
    case codexRollout
    /// No history adapter yet; only real-time events are shown.
    case realtimeOnly
}

/// Per-CLI capability flags. These drive UI affordances (approve/deny buttons,
/// input bar enablement) and installer behavior (remote install gating).
struct CLICapability: Sendable {
    let historyKind: HistoryKind
    /// True if the CLI's hook surface lets VibeHub approve/deny tool calls
    /// (requires a `PermissionRequest` hook event or an equivalent).
    let canApprove: Bool
    /// True if VibeHub can inject user input back into the CLI (tmux / TTY /
    /// OpenCode control socket / etc).
    let canSendInput: Bool
    /// True if `CLIInstaller.installRemote` should try to install this CLI
    /// when a remote host's SSH tunnel comes up.
    let supportsRemoteInstall: Bool
}
