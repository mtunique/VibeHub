//
//  SupportedCLI.swift
//  VibeHub
//
//  First-class identifier for every CLI that VibeHub can observe.
//  The rawValue is also the string written to `VIBEHUB_SOURCE=<raw>` in
//  the hook command, so it must match what `vibehub-state.py` reports
//  back in the `_source` field of each event payload.
//

import Foundation
import SwiftUI

enum SupportedCLI: String, CaseIterable, Sendable {
    // Phase 0
    case claude
    case opencode
    case codex
    // Phase 1 — Claude forks (enabled once their CLIConfig entries land)
    case qoder
    case droid
    case codebuddy
    // Reserved for Phase 2+: gemini, cursor, copilot

    /// User-facing label rendered in source tags.
    var displayName: String {
        switch self {
        case .claude: return "claude"
        case .opencode: return "opencode"
        case .codex: return "codex"
        case .qoder: return "qoder"
        case .droid: return "droid"
        case .codebuddy: return "codebuddy"
        }
    }

    /// Accent color rendered for the source tag in the notch and chat view.
    /// Kept in sync with `TerminalColors` so forks can be themed without
    /// pulling UI constants into the service layer.
    var themeColor: Color {
        switch self {
        case .claude:    return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .opencode:  return Color(red: 0.40, green: 0.75, blue: 0.45) // TerminalColors.green
        case .codex:     return Color(red: 0.40, green: 0.60, blue: 1.00) // TerminalColors.blue
        case .qoder:     return Color(red: 0.80, green: 0.40, blue: 0.80) // TerminalColors.magenta
        case .droid:     return Color(red: 1.00, green: 0.70, blue: 0.00) // TerminalColors.amber
        case .codebuddy: return Color(red: 0.00, green: 0.80, blue: 0.80) // TerminalColors.cyan
        }
    }

    // MARK: - Resolution

    /// Resolve from the `_source` string injected by hook scripts.
    static func from(sourceString raw: String?) -> SupportedCLI? {
        guard let raw, !raw.isEmpty else { return nil }
        return SupportedCLI(rawValue: raw)
    }

    /// Legacy fallback for events that arrive without an explicit `_source`
    /// field (older installed scripts, OpenCode plugin pre-refactor, ...).
    ///
    /// Only prefixes that previously drove source detection are matched here.
    /// We deliberately do NOT pattern-match on `qoder-` / `droid-` etc.; any
    /// new CLI must carry its identity in `_source` explicitly.
    static func from(sessionIdPrefix sessionId: String) -> SupportedCLI? {
        if sessionId.contains("opencode-") { return .opencode }
        if sessionId.hasPrefix("codex-") { return .codex }
        return nil
    }

    /// Resolve from a raw hook payload (source field → prefix fallback → claude).
    static func resolve(sourceString: String?, sessionId: String) -> SupportedCLI {
        if let explicit = from(sourceString: sourceString) { return explicit }
        if let legacy = from(sessionIdPrefix: sessionId) { return legacy }
        return .claude
    }
}
