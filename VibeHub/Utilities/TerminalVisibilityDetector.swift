//
//  TerminalVisibilityDetector.swift
//  VibeHub
//
//  Detects if terminal windows are visible on current space
//

import AppKit
import CoreGraphics

struct TerminalVisibilityDetector {
    /// Check if any terminal window is visible on the current space
    static func isTerminalVisibleOnCurrentSpace() -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]

        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for window in windowList {
            guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0 else { continue }

            if TerminalAppRegistry.isTerminal(ownerName) {
                return true
            }
        }

        return false
    }

    /// Check if the frontmost (active) application is a terminal
    static func isTerminalFrontmost() -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let bundleId = frontmostApp.bundleIdentifier else {
            return false
        }

        return TerminalAppRegistry.isTerminalBundle(bundleId)
    }

    /// Check if a Claude session is currently focused (user is looking at it)
    /// - Parameter session: The session state to check
    /// - Returns: true if the session's terminal is frontmost and (for multiplexers) the pane is active
    static func isSessionFocused(session: SessionState) async -> Bool {
        guard let sessionPid = session.pid else { return false }

        // If no terminal is frontmost, session is definitely not focused
        guard isTerminalFrontmost() else {
            return false
        }

        let tree = ProcessTreeBuilder.shared.buildTree()
        let mux = ProcessTreeBuilder.shared.detectMultiplexer(pid: sessionPid, tree: tree)

        switch mux {
        case .tmux:
            // For tmux sessions, check if the session's pane is active
            return await TmuxTargetFinder.shared.isSessionPaneActive(claudePid: sessionPid)
        case .zellij:
            // TODO: zellij doesn't expose which pane is focused — assume focused when terminal is frontmost
            return true
        case .none:
            // For non-multiplexer sessions, check if the session's terminal app is frontmost
            guard let sessionTerminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: sessionPid, tree: tree),
                  let frontmostApp = NSWorkspace.shared.frontmostApplication else {
                return false
            }
            return sessionTerminalPid == Int(frontmostApp.processIdentifier)
        }
    }
}
