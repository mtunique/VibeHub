import Combine
import Foundation
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

    func connect(id: String) {
        guard let host = hosts.first(where: { $0.id == id }) else { return }

        desiredConnected.insert(id)
        reconnectAttempts[id] = 0
        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = nil

        Task {
            await RemoteLog.shared.log(.info, "connect requested (\(host.sshTarget))", hostId: id)
        }

        setStatus(id: id, status: .connecting)

        // Start local socket listener for this remote.
        if servers[id] == nil {
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
            servers[id] = server
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
                    // Previously install started concurrently with connect(), racing the
                    // ControlMaster TCP handshake and causing intermittent GSSAPI failures.
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

        // Start forwarding immediately.
        forwarder.connect(host: host)
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
    }

    private func cleanupOrphanedSSHForwards() async {
        // Best effort: if the app crashed, old `ssh -N -R ...` processes may keep running
        // and block new forwards. Only kill processes that reference our per-host local socket.
        let res = await ProcessExecutor.shared.runWithResult(
            "/bin/ps",
            arguments: ["-ax", "-o", "pid=,command="],
            timeoutSeconds: 6
        )

        guard case .success(let r) = res else {
            await RemoteLog.shared.log(.warn, "startup cleanup: ps failed")
            return
        }

        let socketToHost: [String: String] = Dictionary(
            uniqueKeysWithValues: hosts.map { ($0.localSocketPath, $0.id) }
        )

        var killed = 0
        for rawLine in r.output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count < 2 { continue }
            guard let pid = Int(parts[0]) else { continue }
            let cmd = String(parts[1])

            guard cmd.contains("ssh") else { continue }
            guard cmd.contains("/tmp/vibehub.sock") else { continue }

            // Match any of our per-host local sockets.
            guard let (sock, hostId) = socketToHost.first(where: { cmd.contains($0.key) }) else { continue }

            let killRes = await ProcessExecutor.shared.runWithResult(
                "/bin/kill",
                arguments: ["-TERM", String(pid)],
                timeoutSeconds: 2
            )

            switch killRes {
            case .success:
                killed += 1
                await RemoteLog.shared.log(.info, "startup cleanup: killed orphan ssh pid=\(pid) (sock=\(sock))", hostId: hostId)
            case .failure(let e):
                await RemoteLog.shared.log(.warn, "startup cleanup: failed to kill pid=\(pid): \(e.localizedDescription)", hostId: hostId)
            }
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
}
