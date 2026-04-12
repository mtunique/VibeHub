//
//  TerminalActivator.swift
//  VibeHub
//
//  Unified terminal activation: brings the terminal window to front
//  and switches to the correct tab. Supports local, tmux, and remote SSH sessions.
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
        log("activateTerminal: remote=\(session.isRemote) mux=\(session.multiplexer) pid=\(session.pid ?? -1)")
        if session.isRemote {
            return await activateRemoteSession(session)
        }

        switch session.multiplexer {
        case .tmux:
            return await activateTmuxSession(session)
        case .zellij:
            return await activateZellijSession(session)
        case .none:
            return await activateLocalSession(session)
        }
    }

    /// Check if a session's terminal is currently focused.
    /// Works for both local and remote sessions.
    func isSessionTerminalFocused(for session: SessionState) async -> Bool {
        if session.isRemote {
            // For remote sessions, check if the local SSH client terminal is frontmost
            guard let sshPid = await findLocalSSHPid(for: session) else {
                return false
            }
            guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(
                forProcess: sshPid, tree: ProcessTreeBuilder.shared.buildTree()
            ) else { return false }
            return await isAppFrontmost(pid: terminalPid)
        }

        // For local sessions, use the existing detector
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

        log("activateLocalSession pid=\(pid) tty=\(session.tty ?? "nil") mux=\(session.multiplexer)")
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

    // MARK: - Local Zellij Session

    private func activateZellijSession(_ session: SessionState) async -> Bool {
        guard let pid = session.pid else { return false }

        // Switch to the correct zellij pane
        await ZellijController.shared.focusPane(forClaudePid: pid)

        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: pid, tree: tree) else {
            return false
        }

        return await activateApp(pid: terminalPid)
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

    // MARK: - Remote SSH Session

    private func activateRemoteSession(_ session: SessionState) async -> Bool {
        guard let remoteHostId = session.remoteHostId else { return false }

        let host: RemoteHost? = await MainActor.run {
            RemoteManager.shared.hosts.first { $0.id == remoteHostId }
        }
        guard let host else { return false }

        let tree = ProcessTreeBuilder.shared.buildTree()
        let sshTarget = host.sshTarget
        let hostname = host.host

        // Collect all local SSH processes to this host that have a TTY
        // (background tunnels like SSHForwarder have no TTY)
        var sshCandidates: [(pid: Int, tty: String)] = []
        for (pid, info) in tree {
            let cmd = info.command.lowercased()
            guard cmd.contains("ssh") else { continue }
            let hasTarget = info.command.contains(sshTarget) || info.command.contains(hostname)
            guard hasTarget else { continue }
            if let tty = getLocalTTY(forPid: pid) {
                sshCandidates.append((pid: pid, tty: tty))
            }
        }

        log("activateRemoteSession: found \(sshCandidates.count) SSH candidates for host=\(hostname)")

        // Try to match the correct SSH candidate when there are multiple
        var targetTTY: String?
        if sshCandidates.count > 1, let clientPort = session.sshClientPort {
            log("activateRemoteSession: ssh client port from hook=\(clientPort)")
            // Try direct port match first (works without ProxyJump)
            targetTTY = findLocalTTYBySourcePort(clientPort, candidates: sshCandidates)
            log("activateRemoteSession: port matched targetTTY=\(targetTTY ?? "nil")")
        }
        // Fallback: query remote to find which local SSH process owns this session's TTY
        if targetTTY == nil, sshCandidates.count > 1,
           let remoteTTY = session.tty, !remoteTTY.isEmpty {
            targetTTY = await matchByRemoteTTY(host: host, remoteTTY: remoteTTY, candidates: sshCandidates)
            log("activateRemoteSession: tty-exec matched targetTTY=\(targetTTY ?? "nil")")
        }

        // Use matched TTY, or fall back to first candidate
        let chosen: (pid: Int, tty: String)?
        if let targetTTY {
            chosen = sshCandidates.first(where: { $0.tty == targetTTY })
        } else {
            chosen = sshCandidates.first
        }

        guard let chosen else {
            log("activateRemoteSession: no SSH terminal found for host=\(hostname)")
            return false
        }

        if let bundleId = await activateTerminalApp(forProcess: chosen.pid, tree: tree) {
            log("activateRemoteSession: activating ssh pid=\(chosen.pid) tty=\(chosen.tty)")
            await TerminalTabSwitcher.switchToTab(bundleId: bundleId, tty: chosen.tty, cwd: nil)
            return true
        }

        return false
    }

    /// Find which local SSH candidate has a TCP connection with the given source port.
    private nonisolated func findLocalTTYBySourcePort(_ clientPort: String, candidates: [(pid: Int, tty: String)]) -> String? {
        // Use lsof to find which SSH process uses this source port
        guard let output = ProcessExecutor.shared.runSyncOrNil(
            "/usr/sbin/lsof", arguments: ["-n", "-P", "-i", "TCP", "-a", "-c", "ssh", "-F", "pcn"]
        ) else { return nil }

        let candidatePids = Set(candidates.map(\.pid))

        // Build child→parent map for SSH processes so we can match ProxyCommand children
        // to their parent SSH process (which owns the TTY).
        var childToParent: [Int: Int] = [:]
        if let psOutput = ProcessExecutor.shared.runSyncOrNil(
            "/bin/ps", arguments: ["-A", "-o", "pid=,ppid=,comm="]
        ) {
            for line in psOutput.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 2)
                guard parts.count >= 3, parts[2].contains("ssh") else { continue }
                if let child = Int(parts[0]), let parent = Int(parts[1]) {
                    childToParent[child] = parent
                }
            }
        }

        // Parse lsof field output: p<pid>, c<command>, n<connection>
        var currentPid: Int?
        for line in output.split(separator: "\n").map(String.init) {
            if line.hasPrefix("p") {
                currentPid = Int(line.dropFirst())
            } else if line.hasPrefix("n"), let pid = currentPid {
                // n like "192.168.1.1:54321->10.0.0.1:22"
                if line.contains(":\(clientPort)->") {
                    // Direct match
                    if let match = candidates.first(where: { $0.pid == pid }) {
                        return match.tty
                    }
                    // ProxyCommand child: check if parent is a candidate
                    if let parent = childToParent[pid],
                       let match = candidates.first(where: { $0.pid == parent }) {
                        return match.tty
                    }
                }
            }
        }

        return nil
    }

    /// Match a remote session's TTY to a local SSH candidate by querying the remote host.
    /// Uses `who` to find the login time for the remote TTY, then matches against
    /// the start time of each local SSH candidate process.
    private func matchByRemoteTTY(host: RemoteHost, remoteTTY: String, candidates: [(pid: Int, tty: String)]) async -> String? {
        // Get the login timestamp for this TTY on the remote via `who`
        // remoteTTY is like "pts/23" (without /dev/ prefix)
        let devTTY = remoteTTY.hasPrefix("/dev/") ? remoteTTY : "/dev/\(remoteTTY)"
        let shortTTY = remoteTTY.replacingOccurrences(of: "/dev/", with: "")
        let cmd = "who | grep '\\b\(shortTTY)\\b' | head -1"
        let (output, exitCode) = await RemoteManager.shared.exec(hostId: host.id, command: cmd)
        guard exitCode == 0, !output.isEmpty else {
            log("matchByRemoteTTY: who query failed, exit=\(exitCode)")
            return nil
        }
        log("matchByRemoteTTY: who output=\(output.trimmingCharacters(in: .whitespacesAndNewlines))")

        // Parse who output: "user  pts/23  2026-04-07 20:29 (10.x.x.x)"
        // Extract the timestamp part
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
        // Find the date part (YYYY-MM-DD) and time part (HH:MM)
        var remoteDateStr: String?
        for (i, part) in parts.enumerated() {
            if part.count == 10, part.contains("-"),
               i + 1 < parts.count, parts[i + 1].contains(":") {
                remoteDateStr = "\(part) \(parts[i + 1])"
                break
            }
        }

        guard let remoteDateStr else {
            log("matchByRemoteTTY: could not parse date from who output")
            return nil
        }

        // Parse the remote login time
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.timeZone = TimeZone.current  // who shows local time
        guard let remoteLoginTime = df.date(from: remoteDateStr) else {
            log("matchByRemoteTTY: could not parse date '\(remoteDateStr)'")
            return nil
        }

        // Get start time of each local SSH candidate and find closest match
        var bestMatch: (tty: String, delta: TimeInterval)?
        for candidate in candidates {
            guard let startOutput = ProcessExecutor.shared.runSyncOrNil(
                "/bin/ps", arguments: ["-p", String(candidate.pid), "-o", "lstart="]
            ) else { continue }
            let trimmed = startOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // ps lstart format: "Mon Jan  2 15:04:05 2006"
            let psdf = DateFormatter()
            psdf.dateFormat = "EEE MMM  d HH:mm:ss yyyy"
            psdf.locale = Locale(identifier: "en_US_POSIX")
            // Also try single-space day format
            let psdf2 = DateFormatter()
            psdf2.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            psdf2.locale = Locale(identifier: "en_US_POSIX")

            guard let localStart = psdf.date(from: trimmed) ?? psdf2.date(from: trimmed) else {
                log("matchByRemoteTTY: could not parse lstart '\(trimmed)'")
                continue
            }

            let delta = abs(localStart.timeIntervalSince(remoteLoginTime))
            log("matchByRemoteTTY: candidate tty=\(candidate.tty) pid=\(candidate.pid) delta=\(Int(delta))s")
            if bestMatch == nil || delta < bestMatch!.delta {
                bestMatch = (candidate.tty, delta)
            }
        }

        // Only accept if the best match is within 2 minutes (SSH connection setup time)
        guard let best = bestMatch, best.delta < 120 else {
            log("matchByRemoteTTY: no close time match found")
            return nil
        }

        return best.tty
    }

    /// Find a local SSH process that connects to the given remote session's host
    /// and runs inside a terminal (not a background tunnel).
    private func findLocalSSHPid(for session: SessionState) async -> Int? {
        guard let remoteHostId = session.remoteHostId else { return nil }

        let host: RemoteHost? = await MainActor.run {
            RemoteManager.shared.hosts.first { $0.id == remoteHostId }
        }
        guard let host else { return nil }

        let tree = ProcessTreeBuilder.shared.buildTree()
        let sshTarget = host.sshTarget
        let hostname = host.host

        for (pid, info) in tree {
            let cmd = info.command.lowercased()
            guard cmd.contains("ssh") else { continue }

            let hasTarget = info.command.contains(sshTarget) || info.command.contains(hostname)
            guard hasTarget else { continue }

            if ProcessTreeBuilder.shared.findTerminalPid(forProcess: pid, tree: tree) != nil {
                return pid
            }
        }

        return nil
    }

    /// Get the local TTY name for a process (e.g. "ttys005")
    private nonisolated func getLocalTTY(forPid pid: Int) -> String? {
        guard let output = ProcessExecutor.shared.runSyncOrNil(
            "/bin/ps", arguments: ["-p", String(pid), "-o", "tty="]
        ) else { return nil }
        let tty = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tty.isEmpty, tty != "??" else { return nil }
        // ps returns "ttys005", which is what TerminalTabSwitcher expects
        return tty
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
