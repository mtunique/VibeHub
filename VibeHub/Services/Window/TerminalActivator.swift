//
//  TerminalActivator.swift
//  VibeHub
//
//  Unified terminal activation: brings the terminal window to front
//  and switches to the correct tab. Supports local and tmux sessions.
//

import AppKit
import Foundation

/// Activates the terminal window for a session, bringing it to the foreground
/// and switching to the correct tab when possible.
actor TerminalActivator {
    static let shared = TerminalActivator()

    private init() {}

    // MARK: - Public API

    /// Activate the terminal for the given session.
    /// Returns true if the terminal was successfully activated.
    @discardableResult
    func activateTerminal(for session: SessionState) async -> Bool {
        log("activateTerminal: tmux=\(session.isInTmux) pid=\(session.pid ?? -1)")
        if session.isInTmux {
            return await activateTmuxSession(session)
        }

        return await activateLocalSession(session)
    }

    /// Check if a session's terminal is currently focused.
    func isSessionTerminalFocused(for session: SessionState) async -> Bool {
        guard let pid = session.pid else { return false }
        return await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
    }

    // MARK: - Local Non-Tmux Session

    private nonisolated func log(_ msg: String) {
        let line = "\(Date()): \(msg)\n"
        let path = "/tmp/vibehub-activator.log"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8)!)
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
        }
    }

    private func activateLocalSession(_ session: SessionState) async -> Bool {
        guard let pid = session.pid else {
            log("session.pid is nil")
            return false
        }

        log("activateLocalSession pid=\(pid) tty=\(session.tty ?? "nil") isInTmux=\(session.isInTmux)")
        let tree = ProcessTreeBuilder.shared.buildTree()
        log("tree has \(tree.count) entries")

        // Find and activate the terminal app by walking up the process tree
        let bundleId = await activateTerminalApp(forProcess: pid, tree: tree)
        guard let bundleId else {
            log("no terminal app found in tree")
            return false
        }
        log("activated \(bundleId)")

        // Try to switch to the correct tab if supported
        await TerminalTabSwitcher.switchToTab(bundleId: bundleId, tty: session.tty, cwd: session.cwd)

        return true
    }

    /// Walk up the process tree, find the terminal NSRunningApplication, activate it, and return its bundle ID.
    @MainActor
    private func activateTerminalApp(forProcess pid: Int, tree: [Int: ProcessInfo]) -> String? {
        let runningApps = NSWorkspace.shared.runningApplications
        var current = pid
        var depth = 0

        while current > 1 && depth < 20 {
            let app = runningApps.first(where: { $0.processIdentifier == pid_t(current) })
            let bundleId = app?.bundleIdentifier
            let isTerminal = bundleId.map { TerminalAppRegistry.isTerminalBundle($0) } ?? false
            let cmd = tree[current]?.command.prefix(60) ?? "NOT IN TREE"

            log("  walk[\(depth)] pid=\(current) cmd=\(cmd) bundle=\(bundleId ?? "nil") isTerminal=\(isTerminal)")

            if let app, let bundleId, isTerminal {
                app.activate()
                return bundleId
            }

            if let info = tree[current] {
                current = info.ppid
            } else {
                // Process not in tree (e.g. login owned by root) — try sysctl to get ppid
                var kinfo = kinfo_proc()
                var size = MemoryLayout<kinfo_proc>.size
                var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(current)]
                if sysctl(&mib, 4, &kinfo, &size, nil, 0) == 0 && size > 0 {
                    let ppid = Int(kinfo.kp_eproc.e_ppid)
                    log("  walk[\(depth)] pid=\(current) not in tree, sysctl ppid=\(ppid)")
                    current = ppid
                } else {
                    log("  walk[\(depth)] pid=\(current) NOT IN TREE and sysctl failed — stopping")
                    break
                }
            }
            depth += 1
        }

        return nil
    }

    // MARK: - Local Tmux Session

    private func activateTmuxSession(_ session: SessionState) async -> Bool {
        guard let pid = session.pid else { return false }

        // Try yabai first (more precise window management)
        let yabaiResult = await YabaiController.shared.focusWindow(forClaudePid: pid)
        if yabaiResult { return true }

        // Fallback: switch tmux pane + activate terminal via NSRunningApplication
        if let target = await TmuxController.shared.findTmuxTarget(forClaudePid: pid) {
            _ = await TmuxController.shared.switchToPane(target: target)
        }

        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: pid, tree: tree) else {
            return false
        }

        return await activateApp(pid: terminalPid)
    }

    // MARK: - NSRunningApplication Helpers

    /// Activate the app owning the given PID (must run on MainActor for AppKit safety)
    @MainActor
    private func activateApp(pid: Int) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier == pid_t(pid)
        }) else {
            return false
        }

        return app.activate()
    }

    /// Check if the app owning the given PID is the frontmost application
    @MainActor
    private func isAppFrontmost(pid: Int) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        return frontmost.processIdentifier == pid_t(pid)
    }

    /// Get the bundle identifier for a running app by PID
    @MainActor
    private func bundleIdForPid(_ pid: Int) -> String? {
        NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier == pid_t(pid)
        }?.bundleIdentifier
    }
}
