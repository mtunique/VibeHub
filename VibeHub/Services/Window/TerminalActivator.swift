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
        log("activateTerminal: remote=\(session.isRemote) tmux=\(session.isInTmux) pid=\(session.pid ?? -1)")
        if session.isRemote {
            return await activateRemoteSession(session)
        }

        if session.isInTmux {
            return await activateTmuxSession(session)
        }

        return await activateLocalSession(session)
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

        // If multiple candidates, query remote to find the exact match
        var targetTTY: String?
        if sshCandidates.count > 1, let remotePid = session.pid {
            if let clientPort = await queryRemoteSSHClientPort(host: host, remotePid: remotePid) {
                log("activateRemoteSession: remote client port=\(clientPort)")
                targetTTY = findLocalTTYBySourcePort(clientPort, candidates: sshCandidates)
                log("activateRemoteSession: matched targetTTY=\(targetTTY ?? "nil")")
            }
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

    /// Query the remote host to find the SSH client source port for a given remote PID.
    /// Uses the existing native SSH session (no process spawning).
    private func queryRemoteSSHClientPort(host: RemoteHost, remotePid: Int) async -> String? {
        let script = """
        import subprocess, sys

        pid = int(sys.argv[1])
        pp = {}
        for line in subprocess.check_output(['ps', '-eo', 'pid=,ppid='], text=True).splitlines():
            p = line.strip().split()
            if len(p) != 2: continue
            try: pp[int(p[0])] = int(p[1])
            except Exception: continue

        cur = pid
        sshd_pid = None
        for _ in range(100):
            if cur <= 1: break
            try:
                comm = subprocess.check_output(['ps', '-p', str(cur), '-o', 'comm='], text=True).strip()
            except Exception:
                cur = pp.get(cur, 0)
                continue
            if 'sshd' in comm:
                sshd_pid = cur
                break
            cur = pp.get(cur, 0)

        if not sshd_pid:
            sys.exit(1)

        def found(port):
            print(port)
            sys.exit(0)

        # Method 1: /proc/<pid>/environ (Linux)
        try:
            env = open(f'/proc/{sshd_pid}/environ', 'rb').read()
            for kv in env.split(b'\\x00'):
                if kv.startswith(b'SSH_CLIENT='):
                    parts = kv.split(b'=', 1)[1].decode().split()
                    if len(parts) >= 2:
                        found(parts[1])
        except Exception: pass

        # Method 2: lsof (macOS, most Linux)
        try:
            out = subprocess.check_output(
                ['lsof', '-a', '-p', str(sshd_pid), '-i', 'TCP', '-n', '-P', '-F', 'n'],
                text=True, stderr=subprocess.DEVNULL
            )
            for line in out.splitlines():
                if line.startswith('n') and '->' in line:
                    peer = line.split('->')[1]
                    found(peer.rsplit(':', 1)[-1])
        except Exception: pass

        # Method 3: ss (Linux without lsof)
        try:
            out = subprocess.check_output(['ss', '-tnp'], text=True, stderr=subprocess.DEVNULL)
            for line in out.splitlines():
                if f'pid={sshd_pid}' in line:
                    parts = line.split()
                    if len(parts) >= 5:
                        found(parts[4].rsplit(':', 1)[-1])
        except Exception: pass

        sys.exit(1)
        """

        let remoteCmd = "python3 - \(remotePid) <<'PY'\n\(script)\nPY"
        let (output, exitCode) = await RemoteManager.shared.exec(hostId: host.id, command: remoteCmd)
        log("queryRemoteSSHClientPort: exit=\(exitCode) output=\(output.prefix(100))")
        guard exitCode == 0 else { return nil }
        let port = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return port.isEmpty ? nil : port
    }

    /// Find which local SSH candidate has a TCP connection with the given source port.
    private nonisolated func findLocalTTYBySourcePort(_ clientPort: String, candidates: [(pid: Int, tty: String)]) -> String? {
        // Use lsof to find which SSH process uses this source port
        guard let output = ProcessExecutor.shared.runSyncOrNil(
            "/usr/sbin/lsof", arguments: ["-n", "-P", "-i", "TCP", "-a", "-c", "ssh", "-F", "pcn"]
        ) else { return nil }

        // Parse lsof field output: p<pid>, c<command>, n<connection>
        var currentPid: Int?
        for line in output.split(separator: "\n").map(String.init) {
            if line.hasPrefix("p") {
                currentPid = Int(line.dropFirst())
            } else if line.hasPrefix("n"), let pid = currentPid {
                // n like "192.168.1.1:54321->10.0.0.1:22"
                if line.contains(":\(clientPort)->") {
                    if let match = candidates.first(where: { $0.pid == pid }) {
                        return match.tty
                    }
                }
            }
        }

        return nil
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
