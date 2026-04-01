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

    private var servers: [String: HookSocketServer] = [:]
    private var forwarders: [String: SSHForwarder] = [:]
    private var installTasks: [String: Task<Void, Never>] = [:]

    private let logger = Logger(subsystem: "com.claudeisland", category: "Remote")

    private init() {
        if let stored: [RemoteHost] = AppSettings.getRemoteHosts([RemoteHost].self) {
            hosts = stored
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

    func connect(id: String) {
        guard let host = hosts.first(where: { $0.id == id }) else { return }

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
        forwarder.$status
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in
                self?.setStatus(id: id, status: s)
            }
            .store(in: &RemoteCancellables.shared.set)

        // Start forwarding immediately; install can run in parallel.
        forwarder.connect(host: host)

        installTasks[id]?.cancel()
        installTasks[id] = Task.detached { [weak self] in
            guard let self else { return }

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

            let report = await RemoteInstaller.installAllWithTimeout(host: host)
            await MainActor.run {
                var next = self.lastInstallReport
                next[id] = report
                self.lastInstallReport = next
            }
        }
    }

    func disconnect(id: String) {
        installTasks[id]?.cancel()
        installTasks.removeValue(forKey: id)

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

    private func setStatus(id: String, status: SSHForwarder.Status) {
        var next = connectionStatus
        next[id] = status
        connectionStatus = next
        logger.debug("Remote \(id, privacy: .public) status: \(String(describing: status), privacy: .public)")
    }
}

// Shared cancellables for RemoteManager subscriptions
@MainActor
private final class RemoteCancellables {
    static let shared = RemoteCancellables()
    var set: Set<AnyCancellable> = []
}
