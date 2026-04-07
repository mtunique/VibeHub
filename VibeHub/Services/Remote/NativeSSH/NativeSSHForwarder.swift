import Clibssh
import Combine
import Darwin
import Foundation

/// Drop-in replacement for SSHForwarder using native libssh instead of spawning /usr/bin/ssh.
/// Establishes a reverse TCP port forward: the remote hook connects to 127.0.0.1:PORT
/// and libssh proxies each connection to the local HookSocketServer Unix socket.
@MainActor
final class NativeSSHForwarder: ObservableObject {
    typealias Status = SSHForwarder.Status

    @Published private(set) var status: Status = .disconnected

    private var runner: SSHRunner?
    private var processForwarder: ProcessForwarder?
    private var hostId: String?
    private var generation: UInt64 = 0
    /// True when using process-based forwarding (ProxyJump / GSSAPI-only hosts).
    private var usingProcessMode = false

    func connect(host: RemoteHost) {
        hostId = host.id
        disconnect()
        generation &+= 1
        let gen = generation
        status = .connecting

        // Detect if ProxyJump is configured — libssh can't handle GSSAPI through proxies.
        let needsProcess = SSHRunner.detectProxyJump(host: host) != nil
        usingProcessMode = needsProcess

        if needsProcess {
            Task { await RemoteLog.shared.log(.info, "Using process-based SSH (ProxyJump detected)", hostId: host.id) }
            let pf = ProcessForwarder()
            processForwarder = pf
            pf.start(host: host) { [weak self] newStatus in
                DispatchQueue.main.async {
                    guard let self, self.generation == gen else { return }
                    self.status = newStatus
                }
            }
        } else {
            let r = SSHRunner()
            runner = r
            r.start(host: host) { [weak self] newStatus in
                DispatchQueue.main.async {
                    guard let self, self.generation == gen else { return }
                    self.status = newStatus
                }
            }
        }
    }

    func disconnect() {
        runner?.stop()
        runner = nil
        processForwarder?.stop()
        processForwarder = nil
    }

    /// Execute a command on the remote host via the existing SSH session.
    /// Returns (stdout, exitCode). Returns ("", -1) if not connected.
    func exec(command: String) async -> (output: String, exitCode: Int32) {
        if usingProcessMode {
            guard let pf = processForwarder else { return ("", -1) }
            return await pf.exec(command: command)
        }
        guard let runner else { return ("", -1) }
        return await withCheckedContinuation { cont in
            runner.enqueueExec(command) { output, exitCode in
                cont.resume(returning: (output, exitCode))
            }
        }
    }
}

// MARK: - ProcessForwarder

/// Process-based SSH tunnel for hosts that require ProxyJump/GSSAPI.
/// Uses `/usr/bin/ssh -N -R` for the tunnel and ControlMaster for exec.
private final class ProcessForwarder: @unchecked Sendable {
    private var process: Process?
    private var host: RemoteHost?
    private var shouldStop = false

    func start(host: RemoteHost, onStatus: @escaping (SSHForwarder.Status) -> Void) {
        self.host = host
        let controlDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibehub", isDirectory: true)
        try? FileManager.default.createDirectory(at: controlDir, withIntermediateDirectories: true)
        let controlPath = controlDir.appendingPathComponent("ssh-%C").path

        var args: [String] = [
            "-N", "-T",
            "-o", "BatchMode=yes",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-o", "StreamLocalBindUnlink=yes",
            "-o", "StreamLocalBindMask=0000",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=300",
        ]
        if host.useGSSAPI {
            args += ["-o", "PreferredAuthentications=gssapi-with-mic"]
        }
        if let port = host.port { args += ["-p", String(port)] }
        if let key = host.identityFile, !key.isEmpty { args += ["-i", key] }
        args += ["-R", "\(host.remoteSocketPath):\(host.localSocketPath)"]
        args += [host.sshTarget]

        let sshCmd = (["/usr/bin/ssh"] + args)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", sshCmd]
        p.environment = RemoteInstaller.getSSHEnvironment()

        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice

        p.terminationHandler = { [weak self] proc in
            guard let self, !self.shouldStop else { return }
            let code = proc.terminationStatus
            if code == 0 { return }  // ControlMaster multiplexed exit
            Task { await RemoteLog.shared.log(.warn, "ssh process exited (\(code))", hostId: host.id) }
            onStatus(.failed("ssh exited (\(code))"))
        }

        do {
            try p.run()
            process = p
            Task { await RemoteLog.shared.log(.info, "ssh process started pid=\(p.processIdentifier)", hostId: host.id) }
        } catch {
            onStatus(.failed("ssh start failed"))
            return
        }

        // Monitor stderr for connection status
        let handle = errPipe.fileHandleForReading
        handle.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty, let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !msg.isEmpty else { return }
            Task { await RemoteLog.shared.log(.debug, "ssh stderr: \(msg)", hostId: host.id) }
        }

        // Mark connected after a short delay (same heuristic as SSHForwarder)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self, weak p] in
            guard let self, !self.shouldStop, let p, p.isRunning else { return }
            onStatus(.connected)
        }
    }

    func stop() {
        shouldStop = true
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }

    func exec(command: String) async -> (output: String, exitCode: Int32) {
        guard let host else { return ("", -1) }
        let result = await RemoteInstaller.runSSHResult(host: host, command: command, timeoutSeconds: 10)
        return (result.output, result.exitCode)
    }
}

// MARK: - SSHRunner

/// Manages a libssh session on a dedicated OS thread.
/// All libssh calls happen on that single thread to satisfy libssh's thread-safety requirement.
private final class SSHRunner: @unchecked Sendable {
    private var shouldStop = false
    private var session: OpaquePointer?  // ssh_session — access only from SSH thread

    // MARK: - Remote command execution queue

    private struct ExecRequest {
        let command: String
        let completion: @Sendable (String, Int32) -> Void
    }

    private let execLock = NSLock()
    private var pendingExecs: [ExecRequest] = []

    /// Enqueue a command to be executed on the SSH thread. Thread-safe.
    func enqueueExec(_ command: String, completion: @escaping @Sendable (String, Int32) -> Void) {
        execLock.lock()
        pendingExecs.append(ExecRequest(command: command, completion: completion))
        execLock.unlock()
    }

    func start(host: RemoteHost, onStatus: @escaping (SSHForwarder.Status) -> Void) {
        let t = Thread { [weak self] in
            self?.run(host: host, onStatus: onStatus)
        }
        t.name = "com.vibehub.ssh"
        t.qualityOfService = .utility
        t.start()
    }

    func stop() {
        shouldStop = true
        // Interrupt blocking libssh calls by disconnecting the session.
        // Safe to call from another thread — ssh_disconnect is the documented way to wake up a blocked poll.
        if let s = session {
            ssh_disconnect(s)
        }
    }

    // MARK: Session lifecycle (runs entirely on SSH thread)

    private func run(host: RemoteHost, onStatus: @escaping (SSHForwarder.Status) -> Void) {
        // Initialize libssh + mbedTLS crypto (RNG, entropy) on this thread.
        let initRC = vibehub_ssh_global_init()
        if initRC != 0 {
            onStatus(.failed("libssh init failed (\(initRC))"))
            return
        }

        guard let s = ssh_new() else {
            onStatus(.failed("ssh_new failed"))
            return
        }
        session = s
        defer {
            ssh_disconnect(s)
            ssh_free(s)
            session = nil
        }

        if let err = setupOptions(s, host: host) {
            onStatus(.failed(err))
            return
        }

        if ssh_connect(s) != SSH_OK {
            onStatus(.failed("connect: \(sshError(s))"))
            return
        }

        if let err = verifyHostKey(s, host: host) {
            onStatus(.failed(err))
            return
        }

        if let err = authenticate(s, host: host) {
            onStatus(.failed(err))
            return
        }

        var boundPort: Int32 = 0
        if ssh_channel_listen_forward(s, "127.0.0.1", 0, &boundPort) != SSH_OK {
            onStatus(.failed("listen_forward: \(sshError(s))"))
            return
        }

        // Write the assigned port to the remote so the hook can find it.
        writePortToRemote(s, port: boundPort)

        onStatus(.connected)
        Task { await RemoteLog.shared.log(.info, "native SSH connected, remote TCP port=\(boundPort)", hostId: host.id) }

        let sessionDied = runForwardLoop(s, host: host)

        // Best-effort cleanup of the remote port file.
        // If the session died abruptly this exec may fail silently.
        cleanupPortOnRemote(s)

        // If the loop exited because the session dropped (not a deliberate stop),
        // report failure so RemoteManager can trigger reconnect.
        if sessionDied {
            onStatus(.failed("connection lost"))
        }
    }

    // MARK: Options

    private func setupOptions(_ s: OpaquePointer, host: RemoteHost) -> String? {
        host.host.withCString { ssh_options_set(s, SSH_OPTIONS_HOST, $0) }

        if let port = host.port {
            var p = Int32(port)
            ssh_options_set(s, SSH_OPTIONS_PORT, &p)
        }

        if let user = host.user, !user.isEmpty {
            user.withCString { ssh_options_set(s, SSH_OPTIONS_USER, $0) }
        }

        var timeout: Int = 15
        ssh_options_set(s, SSH_OPTIONS_TIMEOUT, &timeout)

        #if APP_STORE
        // Sandbox: use files copied to container temp dir.
        if let ssh = SSHForwarder.sandboxSSHDir() {
            ssh.knownHosts.withCString { ssh_options_set(s, SSH_OPTIONS_KNOWNHOSTS, $0) }
            // Parse the copied config (ProxyJump, IdentityFile rewrites, etc.)
            ssh_options_parse_config(s, ssh.config)
        }
        #else
        // Dev build: parse system ~/.ssh/config.
        ssh_options_parse_config(s, nil)

        if let key = host.identityFile, !key.isEmpty {
            key.withCString { ssh_options_set(s, SSH_OPTIONS_IDENTITY, $0) }
        }
        #endif

        return nil
    }

    // MARK: ProxyJump detection

    /// Runs `ssh -G <host>` to detect ProxyJump. Returns the jump target or nil.
    static func detectProxyJump(host: RemoteHost) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ["-G", host.host]
        proc.environment = RemoteInstaller.getSSHEnvironment()
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].lowercased() == "proxyjump" {
                let value = String(parts[1])
                return value == "none" ? nil : value
            }
        }
        return nil
    }

    // MARK: Host key verification

    private func verifyHostKey(_ s: OpaquePointer, host: RemoteHost) -> String? {
        let state = ssh_session_is_known_server(s)
        switch state {
        case SSH_KNOWN_HOSTS_OK:
            return nil
        case SSH_KNOWN_HOSTS_UNKNOWN, SSH_KNOWN_HOSTS_NOT_FOUND:
            // Auto-trust on first connect and persist to known_hosts.
            // Production implementations should prompt the user.
            if ssh_session_update_known_hosts(s) != SSH_OK {
                Task { await RemoteLog.shared.log(.warn, "could not update known_hosts: \(sshError(s))", hostId: host.id) }
            }
            return nil
        case SSH_KNOWN_HOSTS_CHANGED:
            return "host key changed — possible MITM attack (\(host.host))"
        case SSH_KNOWN_HOSTS_OTHER:
            return "host key type mismatch for \(host.host)"
        default:
            return "host key check error: \(sshError(s))"
        }
    }

    // MARK: Authentication

    private func authenticate(_ s: OpaquePointer, host: RemoteHost) -> String? {
        // Query which methods the server actually supports.
        // ssh_userauth_none is required first to get the method list.
        let noneRC = ssh_userauth_none(s, nil)
        if noneRC == SSH_AUTH_SUCCESS.rawValue { return nil }

        let methods = ssh_userauth_list(s, nil)

        // GSSAPI first if enabled and available (preferred for corp environments).
        if host.useGSSAPI && (methods & Int32(SSH_AUTH_METHOD_GSSAPI_MIC)) != 0 {
            let rc = ssh_userauth_gssapi(s)
            if rc == SSH_AUTH_SUCCESS.rawValue { return nil }
            Task { await RemoteLog.shared.log(.warn, "GSSAPI auth failed (rc=\(rc))", hostId: host.id) }
        }

        // Public key (agent + key files).
        if (methods & Int32(SSH_AUTH_METHOD_PUBLICKEY)) != 0 {
            let rc = ssh_userauth_publickey_auto(s, nil, nil)
            if rc == SSH_AUTH_SUCCESS.rawValue { return nil }
        }

        return "authentication failed (\(host.host))"
    }

    // MARK: Forward event loop

    /// Returns `true` if the session died unexpectedly (triggers reconnect), `false` on clean stop.
    @discardableResult
    private func runForwardLoop(_ s: OpaquePointer, host: RemoteHost) -> Bool {
        guard let event = ssh_event_new() else { return true }
        defer { ssh_event_free(event) }
        ssh_event_add_session(event, s)

        var proxies: [ProxyEntry] = []

        while !shouldStop {
            let pollResult = ssh_event_dopoll(event, 50)  // 50 ms — drives all channel + connector I/O
            if shouldStop { break }

            // SSH_ERROR from dopoll can mean a channel closed (not necessarily session death).
            // Only treat as fatal if the session itself is disconnected.
            if ssh_is_connected(s) == 0 {
                Task { await RemoteLog.shared.log(.warn, "session disconnected (poll=\(pollResult))", hostId: host.id) }
                cleanupProxies(&proxies, event: event, session: s)
                ssh_event_remove_session(event, s)
                return true  // session died
            }

            // Accept a new incoming forward channel (non-blocking, timeout=0).
            var destPort: Int32 = 0
            var originator: UnsafeMutablePointer<CChar>? = nil
            var originatorPort: Int32 = 0
            let ch = ssh_channel_open_forward_port(s, 0, &destPort, &originator, &originatorPort)
            if let o = originator { free(o) }

            if let ch {
                Task { await RemoteLog.shared.log(.info, "forward channel accepted (destPort=\(destPort))", hostId: host.id) }
                let fd = connectToLocalSocket(host.localSocketPath)
                Task { await RemoteLog.shared.log(.info, "local socket connect fd=\(fd) path=\(host.localSocketPath)", hostId: host.id) }
                if fd >= 0 {
                    fcntl(fd, F_SETFL, O_NONBLOCK)

                    // socket → channel
                    let c1 = ssh_connector_new(s)!
                    ssh_connector_set_in_fd(c1, fd)
                    ssh_connector_set_out_channel(c1, ch, SSH_CONNECTOR_STDOUT)
                    ssh_event_add_connector(event, c1)

                    // channel → socket
                    let c2 = ssh_connector_new(s)!
                    ssh_connector_set_in_channel(c2, ch, SSH_CONNECTOR_STDOUT)
                    ssh_connector_set_out_fd(c2, fd)
                    ssh_event_add_connector(event, c2)

                    proxies.append(ProxyEntry(ch: ch, c1: c1, c2: c2, fd: fd))
                } else {
                    ssh_channel_close(ch)
                    ssh_channel_free(ch)
                }
            }

            // Process any pending remote exec requests
            drainPendingExecs(s)

            // Reap closed channels.
            // 回收已关闭的 channel
            proxies = proxies.filter { p in
                guard ssh_channel_is_eof(p.ch) != 0 || ssh_channel_is_closed(p.ch) != 0 else {
                    return true
                }
                freeProxy(p, event: event)
                return false
            }
        }

        cleanupProxies(&proxies, event: event, session: s)
        ssh_event_remove_session(event, s)
        return false  // 正常退出
    }

    private func freeProxy(_ p: ProxyEntry, event: OpaquePointer) {
        ssh_event_remove_connector(event, p.c1)
        ssh_event_remove_connector(event, p.c2)
        ssh_connector_free(p.c1)
        ssh_connector_free(p.c2)
        ssh_channel_close(p.ch)
        ssh_channel_free(p.ch)
        Darwin.close(p.fd)
    }

    private func cleanupProxies(_ proxies: inout [ProxyEntry], event: OpaquePointer, session: OpaquePointer) {
        for p in proxies { freeProxy(p, event: event) }
        proxies.removeAll()
    }

    // MARK: Remote command execution

    /// Drain the pending exec queue on the SSH thread.
    private func drainPendingExecs(_ s: OpaquePointer) {
        execLock.lock()
        let requests = pendingExecs
        pendingExecs.removeAll()
        execLock.unlock()

        for req in requests {
            let (output, exitCode) = execWithOutput(s, command: req.command)
            req.completion(output, exitCode)
        }
    }

    /// Execute a command and return (stdout, exit_code). Runs on the SSH thread.
    private func execWithOutput(_ s: OpaquePointer, command: String) -> (String, Int32) {
        guard let ch = ssh_channel_new(s) else { return ("", -1) }
        defer {
            ssh_channel_close(ch)
            ssh_channel_free(ch)
        }
        guard ssh_channel_open_session(ch) == SSH_OK else { return ("", -1) }

        var rc: Int32 = -1
        command.withCString { rc = ssh_channel_request_exec(ch, $0) }
        guard rc == SSH_OK else { return ("", -1) }

        // Read stdout with timeout
        var output = Data()
        var buf = [CChar](repeating: 0, count: 4096)
        while true {
            let n = ssh_channel_read_timeout(ch, &buf, UInt32(buf.count), 0, 5000)
            if n <= 0 { break }
            output.append(Data(bytes: buf, count: Int(n)))
        }

        ssh_channel_send_eof(ch)
        // Drain until remote closes
        while ssh_channel_is_eof(ch) == 0 {
            let _ = ssh_channel_read_timeout(ch, &buf, UInt32(buf.count), 0, 1000)
        }
        let exitStatus = ssh_channel_get_exit_status(ch)

        return (String(data: output, encoding: .utf8) ?? "", exitStatus)
    }

    // MARK: Remote port file helpers

    private func writePortToRemote(_ s: OpaquePointer, port: Int32) {
        execRemoteCommand(s, command: "printf '%d\\n' \(port) > /tmp/vibehub.port")
    }

    private func cleanupPortOnRemote(_ s: OpaquePointer) {
        execRemoteCommand(s, command: "rm -f /tmp/vibehub.port")
    }

    /// Opens a one-shot exec channel, runs the command, and closes immediately.
    private func execRemoteCommand(_ s: OpaquePointer, command: String) {
        guard let ch = ssh_channel_new(s) else { return }
        defer { ssh_channel_free(ch) }
        guard ssh_channel_open_session(ch) == SSH_OK else { return }
        command.withCString { ssh_channel_request_exec(ch, $0) }
        ssh_channel_send_eof(ch)
        ssh_channel_close(ch)
    }

    // MARK: Local socket connection

    private func connectToLocalSocket(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { buf in
                    strncpy(buf, src, maxLen)
                }
            }
        }

        let result = withUnsafePointer(to: addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if result != 0 {
            Darwin.close(fd)
            return -1
        }
        return fd
    }

    // MARK: Helpers

    private func sshError(_ s: OpaquePointer) -> String {
        let ptr = UnsafeMutableRawPointer(s)
        guard let err = ssh_get_error(ptr) else { return "unknown error" }
        return String(cString: err)
    }

    private struct ProxyEntry {
        let ch: OpaquePointer   // ssh_channel
        let c1: OpaquePointer   // ssh_connector (socket → channel)
        let c2: OpaquePointer   // ssh_connector (channel → socket)
        let fd: Int32           // local Unix socket fd
    }
}
