import Combine
import Foundation

@MainActor
final class SSHForwarder: ObservableObject {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var status: Status = .disconnected

    private var process: Process?
    private var stderrPipe: Pipe?
    private var hostId: String?
    /// Monotonically increasing counter incremented on each connect(). Stale
    /// terminationHandler / stderrMonitor callbacks compare their captured
    /// generation to this value and bail out if they no longer match, preventing
    /// old SSH processes from corrupting the current connection status.
    private var generation: UInt64 = 0

    func connect(host: RemoteHost) {
        hostId = host.id
        disconnect()

        generation &+= 1
        let gen = generation

        status = .connecting

        let sshPath = "/usr/bin/ssh"
        let args = buildArgs(host: host)
        let envPrefix = """
SSH_AUTH_SOCK_VAL=$(launchctl getenv SSH_AUTH_SOCK 2>/dev/null || true);
if [ -n \"$SSH_AUTH_SOCK_VAL\" ]; then export SSH_AUTH_SOCK=\"$SSH_AUTH_SOCK_VAL\"; fi;
KRB5CCNAME_VAL=$(launchctl getenv KRB5CCNAME 2>/dev/null || true);
if [ -n \"$KRB5CCNAME_VAL\" ]; then export KRB5CCNAME=\"$KRB5CCNAME_VAL\"; fi;
"""

        let cmd = envPrefix + " " + ([sshPath] + args)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")

        let p = Process()
        // Run via login shell so ssh sees same auth env as Terminal.
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]

        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        stderrPipe = err

        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                // Stale callback from an old SSH process — ignore it.
                guard self.generation == gen else { return }
                if case .disconnected = self.status { return }
                let code = proc.terminationStatus
                // Exit 0 with ControlMaster=auto is normal: SSH multiplexed through an
                // existing master socket and exited cleanly. This is not an error.
                if code == 0 { return }
                self.status = .failed("ssh exited (\(code))")
            }
        }

        do {
            try p.run()
            process = p
            // Only mark connected after we know the process is alive.
            status = .connecting
            startStderrMonitor(err, generation: gen)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak p] in
                guard let self else { return }
                // Stale callback — a newer connect() has started.
                guard self.generation == gen else { return }
                guard let p else { return }
                if p.isRunning {
                    self.status = .connected
                } else if case .connecting = self.status {
                    self.status = .failed("ssh exited")
                }
            }
        } catch {
            status = .failed("ssh start failed")
            process = nil
        }
    }

    func disconnect() {
        if let pipe = stderrPipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }

        if let p = process {
            p.terminate()
        }
        process = nil
        stderrPipe = nil
        // Do NOT set status = .disconnected here. The process terminationHandler
        // (set up when the process was started) will handle the status transition.
        // Calling setStatus(.disconnected) here would trigger scheduleReconnectIfNeeded,
        // which interferes with reconnect() calls that are about to start a new process.
    }

    private func buildArgs(host: RemoteHost) -> [String] {
        var args: [String] = []

        // Avoid /tmp for local ControlMaster sockets.
        let controlDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibehub", isDirectory: true)
        try? FileManager.default.createDirectory(at: controlDir, withIntermediateDirectories: true)
        let controlPath = controlDir.appendingPathComponent("ssh-%C").path

        args += [
            "-N",
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=no",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-o", "StreamLocalBindUnlink=yes",
            // Make the remote unix socket connectable by the actual CLI process user.
            // Default is 0177 (srw-------) which often breaks hooks.
            "-o", "StreamLocalBindMask=0000",
            // Jump proxy and devserver1 only support GSSAPI auth. Using PreferredAuthentications
            // forces gssapi-with-mic first, avoiding the intermittent "Miscellaneous failure" that
            // occurs when SSH tries gssapi-with-mic alongside other methods.
            "-o", "PreferredAuthentications=gssapi-with-mic",
            // ControlMaster=auto: reuse an existing socket if present, otherwise create one.
            // This avoids killing a stale SSH process that holds the socket.
            // ControlPersist=300: keeps the master socket alive for 5 min after the last session.
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=300",
        ]

        if let port = host.port {
            args += ["-p", String(port)]
        }

        if let key = host.identityFile, !key.isEmpty {
            args += ["-i", key]
        }

        // Remote unix socket -> local unix socket
        args += ["-R", "\(host.remoteSocketPath):\(host.localSocketPath)"]
        args += [host.sshTarget]
        return args
    }

    private func startStderrMonitor(_ pipe: Pipe, generation gen: UInt64) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            let msg = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !msg.isEmpty else { return }

            Task { await RemoteLog.shared.log(.debug, "ssh stderr: \(msg)", hostId: self?.hostId) }

            DispatchQueue.main.async {
                guard let self else { return }
                // Stale callback from an old SSH process — ignore it.
                guard self.generation == gen else { return }

                // During connect, treat stderr as failure (eg Permission denied).
                if case .connecting = self.status {
                    self.status = .failed(msg)
                    return
                }

                // When already connected, ignore benign ssh noise (eg known_hosts warnings),
                // but fail hard on forwarding errors.
                if case .connected = self.status {
                    let lower = msg.lowercased()
                    if lower.contains("remote port forwarding failed") ||
                        lower.contains("cannot listen") ||
                        lower.contains("address already in use") {
                        self.status = .failed(msg)
                    }
                }
            }
        }
    }
}
