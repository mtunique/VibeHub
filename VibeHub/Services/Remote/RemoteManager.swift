import Combine
import Foundation
import Darwin
import os.log

@MainActor
final class RemoteManager: ObservableObject {
    static let shared = RemoteManager()

    @Published private(set) var hosts: [RemoteHost] = []
    @Published private(set) var connectionStatus: [String: SSHForwarder.Status] = [:]
    @Published private(set) var lastInstallReport: [String: RemoteInstallReport] = [:]
    @Published private(set) var installRunning: [String: Bool] = [:]
    @Published private(set) var installStartedAt: [String: Date] = [:]

    // Desired connectivity state (used for auto-reconnect)
    private var desiredConnected: Set<String> = []
    private var reconnectAttempts: [String: Int] = [:]
    private var reconnectTasks: [String: Task<Void, Never>] = [:]

    // Tunnel health checks (verify the forwarded unix socket actually works)
    private var healthCheckTasks: [String: Task<Void, Never>] = [:]
    private var pendingHealthToken: [String: String] = [:]
    private var lastHealthSuccessAt: [String: Date] = [:]

    private var servers: [String: HookSocketServer] = [:]
    private var forwarders: [String: SSHForwarder] = [:]
    private var installTasks: [String: Task<Void, Never>] = [:]
    /// Per-host Combine subscription for SSHForwarder status changes.
    /// Replacing the old shared `Set<AnyCancellable>` prevents subscription leaks:
    /// each connect() now cancels the previous subscription before creating a new one.
    private var statusSubscriptions: [String: AnyCancellable] = [:]

    private let logger = Logger(subsystem: "com.vibehub", category: "Remote")

    private init() {
        if let stored: [RemoteHost] = AppSettings.getRemoteHosts([RemoteHost].self) {
            hosts = stored
        }

        Task {
            await RemoteLog.shared.log(.info, "RemoteManager init: \(hosts.count) hosts loaded")
        }
    }

    func startup() {
        // Always do best-effort cleanup (orphan ssh forwards, stale local sockets),
        // then auto-connect hosts marked autoConnect.
        Task { @MainActor in
            let logPath = await RemoteLog.shared.ensureLogFile()
            if let logPath {
                await RemoteLog.shared.log(.info, "remote.log path: \(logPath)")
            } else {
                await RemoteLog.shared.log(.warn, "remote.log unavailable (falling back to OSLog only)")
            }
            await RemoteLog.shared.log(.info, "startup begin: \(hosts.count) hosts")

            await cleanupStaleLocalSockets()
            await cleanupOrphanedSSHForwards()
            await cleanupStaleRemoteSockets()

            await RemoteLog.shared.log(.info, "startup connecting all \(hosts.count) hosts")
            for host in hosts {
                connectWithCleanup(id: host.id)
            }
        }
    }

    func save() {
        AppSettings.setRemoteHosts(hosts)
    }

    func addHost(_ host: RemoteHost) {
        hosts.append(host)
        save()
    }

    func removeHost(id: String) {
        disconnect(id: id)
        hosts.removeAll { $0.id == id }
        save()
    }

    func server(for hostId: String) -> HookSocketServer? {
        servers[hostId]
    }

    func connectWithCleanup(id: String) {
        guard let host = hosts.first(where: { $0.id == id }) else { return }

        // Disconnect any other entries pointing at the same remote host.
        let dupes = hosts.filter { $0.id != id && $0.hostKey == host.hostKey }.map { $0.id }
        for other in dupes {
            Task { await RemoteLog.shared.log(.info, "connect cleanup: disconnect duplicate host entry", hostId: other) }
            disconnect(id: other)
        }

        connect(id: id)
    }

    private func killOrphanedSSH(for host: RemoteHost) async {
        let pids = Self.getAllPids()
        for pid in pids {
            guard let args = Self.getCommandArgs(pid: pid) else { continue }
            let cmd = args.joined(separator: " ")
            
            guard cmd.contains("ssh") else { continue }
            // Kill any old tunnels for this specific remote target, regardless of their local socket UUID,
            // so we don't leak zombies when the host configuration is re-created.
            guard cmd.contains("vibehub.sock") && cmd.contains(host.sshTarget) else { continue }
            
            _ = kill(pid, SIGTERM)
            await RemoteLog.shared.log(.info, "pre-connect cleanup: killed orphan ssh pid=\(pid)", hostId: host.id)
        }
    }

    func connect(id: String) {
        guard let host = hosts.first(where: { $0.id == id }) else { return }

        desiredConnected.insert(id)
        reconnectAttempts[id] = 0
        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = nil

        setStatus(id: id, status: .connecting)

        // Stop any existing server before cleanup — we'll create a fresh one after cleanup
        // to avoid the race where cleanup deletes the socket the server just created.
        if let existing = servers[id] {
            existing.stop()
            servers.removeValue(forKey: id)
        }

        let forwarder = forwarders[id] ?? SSHForwarder()
        forwarders[id] = forwarder

        // Track status. Drop the initial `.disconnected` emission so it doesn't overwrite
        // our optimistic `.connecting` UI state.
        // Cancel any previous subscription for this host to prevent leaks.
        statusSubscriptions[id] = forwarder.$status
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in
                self?.setStatus(id: id, status: s)

                guard let self else { return }
                // Auto-reconnect if desired and the tunnel died.
                switch s {
                case .connected:
                    // A successful connect resets backoff.
                    self.reconnectAttempts[id] = 0
                    // Start install now that the tunnel is confirmed alive.
                    self.startInstallTask(host: host)
                case .failed:
                    self.cancelHealthcheck(hostId: id)
                    self.scheduleReconnectIfNeeded(id: id)
                case .disconnected:
                    self.cancelHealthcheck(hostId: id)
                    self.scheduleReconnectIfNeeded(id: id)
                default:
                    break
                }
            }

        Task {
            // Ensure socket parent directory exists
            let path = host.localSocketPath
            let socketDir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: socketDir, withIntermediateDirectories: true)

            // Pre-connect cleanup (stale local socket and orphan ssh processes for this host)
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
                await RemoteLog.shared.log(.info, "pre-connect cleanup: removed local socket \(path)", hostId: id)
            }
            await killOrphanedSSH(for: host)
            
            // Clean up stale ControlMaster socket
            #if APP_STORE
            // Sandbox: ControlMaster sockets live in /tmp/vh-ssh-*.
            // SSH's ControlMaster=auto handles stale sockets automatically;
            // the sandboxed app may not be able to enumerate /tmp/ directly.
            // Best-effort: try to remove via ssh -O exit.
            #else
            let vibehubDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".vibehub", isDirectory: true)
                .path
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: vibehubDir) {
                for entry in entries where entry.hasPrefix("ssh-") && entry.contains(host.sshTarget) {
                    let cmPath = vibehubDir + "/" + entry
                    try? FileManager.default.removeItem(atPath: cmPath)
                    await RemoteLog.shared.log(.info, "pre-connect cleanup: removed ControlMaster socket \(cmPath)", hostId: id)
                }
            }
            #endif
            
            // Clean up stale remote socket
            _ = await RemoteInstaller.runSSHResult(host: host, command: "rm -f \(host.remoteSocketPath)", timeoutSeconds: 5)

            await RemoteLog.shared.log(.info, "connect requested (\(host.sshTarget))", hostId: id)

            await MainActor.run {
                // Create the local socket listener AFTER cleanup so the cleanup doesn't
                // accidentally delete the socket that the server just bound to.
                if self.servers[id] == nil {
                    let server = HookSocketServer(
                        socketPath: host.localSocketPath,
                        namespacePrefix: host.namespacePrefix,
                        remoteHostId: host.id
                    )

                    server.start(
                        onEvent: { event in
                            Task { await RemoteLog.shared.log(.debug, "event: \(event.event) status=\(event.status)", hostId: id) }

                            // Healthcheck notifications are internal plumbing; don't surface to SessionStore.
                            if event.event == "Notification",
                               event.notificationType == "remote_healthcheck",
                               let msg = event.message,
                               msg.hasPrefix("healthcheck:"),
                               let token = msg.split(separator: ":").dropFirst().first {
                                let tokenString = String(token)
                                Task { @MainActor in
                                    RemoteManager.shared.markHealthcheckReceived(hostId: id, token: tokenString)
                                }
                                return
                            }

                            Task {
                                await SessionStore.shared.process(.hookReceived(event))
                            }

                            if event.event == "Stop" {
                                server.cancelPendingPermissions(sessionId: event.sessionId)
                            }
                            if event.event == "PostToolUse", let toolUseId = event.toolUseId {
                                server.cancelPendingPermission(toolUseId: toolUseId)
                            }
                        },
                        onPermissionFailure: { sessionId, toolUseId in
                            Task {
                                await SessionStore.shared.process(
                                    .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                                )
                            }
                        }
                    )
                    self.servers[id] = server
                }

                // Start forwarding AFTER cleanup completes and server is listening
                forwarder.connect(host: host)
            }
        }
    }

    /// Starts the install task for a host — called when tunnel transitions to .connected.
    private func startInstallTask(host: RemoteHost) {
        let id = host.id
        installTasks[id]?.cancel()
        installTasks[id] = Task.detached { [weak self] in
            guard let self else { return }
            // Wait for the ControlMaster TCP connection to stabilize before sending SSH commands.
            // Without this delay, install commands race the ProxyJump GSSAPI handshake and
            // intermittently hit "Permission denied" because the ControlMaster TCP hasn't
            // finished connecting yet.
            do { try await Task.sleep(for: .seconds(2)) } catch { return }

            await MainActor.run {
                var running = self.installRunning
                running[id] = true
                self.installRunning = running

                var started = self.installStartedAt
                started[id] = Date()
                self.installStartedAt = started
            }

            defer {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    var running = self.installRunning
                    running[id] = false
                    self.installRunning = running
                }
            }

            let report = await RemoteInstaller.installAll(host: host, progress: { stepName in
                await MainActor.run {
                    var started = self.installStartedAt
                    // Force UI refresh even if timestamp exists
                    started[id] = started[id] ?? Date()
                    self.installStartedAt = started
                    self.logger.info("Remote install step: \(stepName, privacy: .public)")
                }
            })
            let summary = report.steps.map { "\($0.ok ? "ok" : "FAIL") \($0.name)" }.joined(separator: ", ")
            await RemoteLog.shared.log(report.ok ? .info : .warn, "install \(report.ok ? "ok" : "failed"): \(summary)", hostId: id)
            for step in report.steps where !step.ok {
                await RemoteLog.shared.log(.warn, "  ↳ stderr: \(step.stderr)", hostId: id)
            }
            await MainActor.run {
                var next = self.lastInstallReport
                next[id] = report
                self.lastInstallReport = next
            }
        }
    }

    func disconnect(id: String) {
        desiredConnected.remove(id)
        reconnectTasks[id]?.cancel()
        reconnectTasks.removeValue(forKey: id)
        reconnectAttempts[id] = nil
        cancelHealthcheck(hostId: id)
        installTasks[id]?.cancel()
        installTasks.removeValue(forKey: id)

        // Cancel the Combine subscription before disconnecting the forwarder,
        // so we don't react to the terminal status change from the old process.
        statusSubscriptions.removeValue(forKey: id)

        forwarders[id]?.disconnect()
        forwarders.removeValue(forKey: id)
        setStatus(id: id, status: .disconnected)

        if let server = servers[id] {
            server.stop()
        }
        servers.removeValue(forKey: id)

        // Cleanup local socket immediately upon disconnect
        if let host = hosts.first(where: { $0.id == id }) {
            let path = host.localSocketPath
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
                Task { await RemoteLog.shared.log(.info, "disconnect cleanup: removed local socket \(path)", hostId: id) }
            }
        }

        var running = installRunning
        running[id] = false
        installRunning = running

        var started = installStartedAt
        started[id] = nil
        installStartedAt = started
    }

    private func scheduleReconnectIfNeeded(id: String) {
        guard desiredConnected.contains(id) else { return }
        guard let host = hosts.first(where: { $0.id == id }) else { return }

        // If we're already connecting or connected, do nothing.
        if case .connecting = connectionStatus[id] {
            return
        }
        if case .connected = connectionStatus[id] {
            return
        }

        let attempt = (reconnectAttempts[id] ?? 0) + 1
        reconnectAttempts[id] = attempt
        let delay = min(60.0, pow(2.0, Double(min(attempt, 6))))

        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = Task.detached {
            await RemoteLog.shared.log(.warn, "reconnect scheduled in \(Int(delay))s (attempt \(attempt))", hostId: id)
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            // Clean up stale remote socket so the tunnel can bind successfully.
            _ = await RemoteInstaller.runSSH(host: host, command: "rm -f \(host.remoteSocketPath)")
            await MainActor.run {
                let mgr = RemoteManager.shared
                guard mgr.desiredConnected.contains(id) else { return }
                // Double-check: if already connected (e.g. a prior reconnect succeeded
                // while this task was sleeping), skip this attempt.
                if case .connected = mgr.connectionStatus[id] { return }
                Task { await RemoteLog.shared.log(.info, "reconnect attempt \(attempt)", hostId: id) }
                mgr.setStatus(id: id, status: .connecting)
                mgr.forwarders[id]?.connect(host: host)
            }
        }
    }

    // MARK: - Startup cleanup

    private func cleanupStaleLocalSockets() async {
        for host in hosts {
            let path = host.localSocketPath
            let existed = FileManager.default.fileExists(atPath: path)
            if existed {
                path.withCString { _ = unlink($0) }
                await RemoteLog.shared.log(.info, "startup cleanup: unlinked local socket \(path)", hostId: host.id)
            }
        }

        #if APP_STORE
        // Sandbox: ControlMaster sockets are in /tmp/vh-ssh-* and may not be
        // enumerable from inside the sandbox. SSH ControlPersist handles expiry.
        #else
        // Also clean up stale ControlMaster sockets from previous runs.
        // These block new ControlMaster=yes connections from starting.
        let fm = FileManager.default
        let socketDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibehub", isDirectory: true)
            .path
        if let entries = try? fm.contentsOfDirectory(atPath: socketDir) {
            for entry in entries where entry.hasPrefix("ssh-") {
                let path = socketDir + "/" + entry
                path.withCString { _ = unlink($0) }
                await RemoteLog.shared.log(.info, "startup cleanup: unlinked stale ControlMaster socket \(path)")
            }
        }
        #endif
    }

    private func cleanupOrphanedSSHForwards() async {
        // Best effort: if the app crashed, old `ssh -N -R ...` processes may keep running
        // and block new forwards. Only kill processes that reference our per-host local socket.
        let pids = Self.getAllPids()

        var killed = 0
        for pid in pids {
            guard let args = Self.getCommandArgs(pid: pid) else { continue }
            let cmd = args.joined(separator: " ")

            guard cmd.contains("ssh") else { continue }
            guard cmd.contains("/tmp/vibehub.sock") else { continue }

            // Match any of our per-host local sockets.
            let isCurrentHost = hosts.contains { cmd.contains($0.localSocketPath) }
            if isCurrentHost { continue }

            _ = kill(pid, SIGTERM)
            killed += 1
            await RemoteLog.shared.log(.info, "startup cleanup: killed orphan ssh pid=\(pid)")
        }

        if killed > 0 {
            await RemoteLog.shared.log(.info, "startup cleanup: killed \(killed) orphan ssh forwards")
        }
    }

    private func cleanupStaleRemoteSockets() async {
        for host in hosts {
            let r = await RemoteInstaller.runSSHResult(host: host, command: "rm -f \(host.remoteSocketPath)", timeoutSeconds: 12)
            await RemoteLog.shared.log(.info, "startup cleanup: remote socket rm exit=\(r.exitCode)", hostId: host.id)
        }
    }

    // MARK: - Tunnel healthcheck

    private func startHealthcheck(host: RemoteHost) {
        let id = host.id
        cancelHealthcheck(hostId: id)

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
        pendingHealthToken[id] = String(token)

        healthCheckTasks[id] = Task { [weak self] in
            guard let self else { return }
            await RemoteLog.shared.log(.info, "healthcheck start token=\(token)", hostId: id)

            let py = """
import json, os, socket, sys, time

sock_path = \"/tmp/vibehub.sock\"
token = sys.argv[1]
event = {
  \"session_id\": f\"healthcheck-{token}\",
  \"cwd\": os.getcwd(),
  \"event\": \"Notification\",
  \"status\": \"notification\",
  \"notification_type\": \"remote_healthcheck\",
  \"message\": f\"healthcheck:{token}\",
}

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(2)
s.connect(sock_path)
s.sendall(json.dumps(event).encode('utf-8'))
s.close()
print(\"sent\", token)
"""

            let cmd = "python3 - '\(token)' <<'PY'\n\(py)\nPY"
            let r = await RemoteInstaller.runSSHResult(host: host, command: cmd, timeoutSeconds: 10)
            if r.exitCode != 0 {
                await RemoteLog.shared.log(.warn, "healthcheck ssh failed exit=\(r.exitCode) stderr=\(r.stderr ?? "")", hostId: id)
                if r.exitCode == 255 {
                    // SSH itself failed (auth/network error) — the tunnel may still be alive.
                    // ServerAliveInterval will catch real disconnects; don't tear down a working tunnel.
                    return
                }
                // Remote script ran but failed (e.g. socket missing, timeout).
                // The tunnel itself is alive. Just retry later.
                return
            }

            // Wait for receipt (the ssh command only proves the remote socket is connectable).
            for _ in 0..<35 {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(100))
                if self.pendingHealthToken[id] != String(token) {
                    return
                }
            }

            // Timed out waiting for event to arrive on the local listener.
            // The tunnel might still be alive — let ServerAliveInterval handle real disconnects.
            await RemoteLog.shared.log(.warn, "healthcheck timeout token=\(token)", hostId: id)
        }
    }

    private func cancelHealthcheck(hostId: String) {
        healthCheckTasks[hostId]?.cancel()
        healthCheckTasks.removeValue(forKey: hostId)
        pendingHealthToken.removeValue(forKey: hostId)
    }

    private func markHealthcheckReceived(hostId: String, token: String) {
        guard pendingHealthToken[hostId] == token else { return }
        pendingHealthToken.removeValue(forKey: hostId)
        lastHealthSuccessAt[hostId] = Date()
        Task { await RemoteLog.shared.log(.info, "healthcheck ok token=\(token)", hostId: hostId) }
    }

    private func setStatus(id: String, status: SSHForwarder.Status) {
        var next = connectionStatus
        next[id] = status
        connectionStatus = next
        logger.debug("Remote \(id, privacy: .public) status: \(String(describing: status), privacy: .public)")

        Task {
            await RemoteLog.shared.log(.info, "status -> \(String(describing: status))", hostId: id)
        }
    }

    // MARK: - Native process discovery

    private static func getAllPids() -> [pid_t] {
        let PROC_ALL_PIDS: UInt32 = 1
        let initialSize = proc_listpids(PROC_ALL_PIDS, 0, nil, 0)
        if initialSize <= 0 { return [] }
        
        var pids = [pid_t](repeating: 0, count: Int(initialSize) / MemoryLayout<pid_t>.size)
        let actualSize = proc_listpids(PROC_ALL_PIDS, 0, &pids, initialSize)
        if actualSize <= 0 { return [] }
        
        return Array(pids.prefix(Int(actualSize) / MemoryLayout<pid_t>.size))
    }

    private static func getCommandArgs(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        if sysctl(&mib, 3, nil, &size, nil, 0) < 0 { return nil }
        
        var buffer = [UInt8](repeating: 0, count: size)
        if sysctl(&mib, 3, &buffer, &size, nil, 0) < 0 { return nil }
        
        // buffer starts with argc (Int32), then exec_path (null terminated), then null padding, then args
        var argc: Int32 = 0
        memcpy(&argc, buffer, MemoryLayout<Int32>.size)
        
        var args = [String]()
        var ptr = MemoryLayout<Int32>.size
        
        // Skip executable path
        while ptr < size && buffer[ptr] != 0 { ptr += 1 }
        // Skip null padding
        while ptr < size && buffer[ptr] == 0 { ptr += 1 }
        
        for _ in 0..<argc {
            if ptr >= size { break }
            let start = ptr
            while ptr < size && buffer[ptr] != 0 { ptr += 1 }
            if ptr > start {
                let str = String(bytes: buffer[start..<ptr], encoding: .utf8) ?? ""
                args.append(str)
            }
            ptr += 1 // Skip null terminator
        }
        return args.isEmpty ? nil : args
    }
}
