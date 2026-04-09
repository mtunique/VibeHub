import Combine
import Foundation

/// SSH forwarder using `/usr/bin/ssh -R` for reverse Unix socket forwarding.
/// Uses ControlMaster for connection multiplexing and remote command execution.
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
    private var host: RemoteHost?
    /// Monotonically increasing counter. Stale callbacks compare their captured
    /// generation to this value and bail out if they no longer match.
    private var generation: UInt64 = 0

    func connect(host: RemoteHost) {
        self.host = host
        disconnect()
        generation &+= 1
        let gen = generation
        status = .connecting

        let args = buildArgs(host: host)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        p.environment = RemoteInstaller.getSSHEnvironment()

        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        stderrPipe = errPipe

        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            if code == 0 { return }  // ControlMaster multiplexed exit
            Task { await RemoteLog.shared.log(.warn, "ssh process exited (\(code))", hostId: host.id) }
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.status = .failed("ssh exited (\(code))")
            }
        }

        do {
            try p.run()
            process = p
            Task { await RemoteLog.shared.log(.info, "ssh process started pid=\(p.processIdentifier)", hostId: host.id) }
        } catch {
            status = .failed("ssh start failed")
            return
        }

        startStderrMonitor(errPipe, generation: gen)

        // Mark connected after a short delay (ssh doesn't signal when the tunnel is ready).
        // Don't check p.isRunning: ControlMaster=auto forks a background master and the
        // original process exits with code 0, which is normal and expected.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.generation == gen else { return }
            if case .connecting = self.status {
                self.status = .connected
            }
        }
    }

    func disconnect() {
        if let pipe = stderrPipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        stderrPipe = nil
    }

    /// Execute a command on the remote host via ControlMaster.
    /// Returns (stdout, exitCode). Returns ("", -1) if not connected.
    func exec(command: String) async -> (output: String, exitCode: Int32) {
        guard let host else { return ("", -1) }
        let result = await RemoteInstaller.runSSHResult(host: host, command: command, timeoutSeconds: 10)
        return (result.output, result.exitCode)
    }

    // MARK: - SSH Arguments

    private func buildArgs(host: RemoteHost) -> [String] {
        var args: [String] = [
            "-N", "-T",
            "-o", "BatchMode=yes",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-o", "StreamLocalBindUnlink=yes",
            "-o", "StreamLocalBindMask=0000",
            "-o", "StrictHostKeyChecking=accept-new",
        ]

        #if APP_STORE
        if let ssh = Self.sandboxSSHDir() {
            args += ["-F", ssh.config]
            args += ["-o", "UserKnownHostsFile=\(ssh.knownHosts)"]
        }
        // Sandbox cannot create Unix sockets in /tmp and container paths
        // exceed the 104-byte sun_path limit, so disable ControlMaster.
        args += ["-o", "ControlMaster=no"]
        #else
        let controlDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibehub", isDirectory: true)
        try? FileManager.default.createDirectory(at: controlDir, withIntermediateDirectories: true)
        let controlPath = controlDir.appendingPathComponent("ssh-%C").path
        args += [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=300",
        ]
        #endif

        if host.useGSSAPI {
            args += ["-o", "PreferredAuthentications=gssapi-with-mic"]
        }
        if let port = host.port { args += ["-p", String(port)] }

        #if !APP_STORE
        if let key = host.identityFile, !key.isEmpty { args += ["-i", key] }
        #endif

        args += ["-R", "\(host.remoteSocketPath):\(host.localSocketPath)"]
        args += [host.sshTarget]
        return args
    }

    // MARK: - Stderr Monitoring

    private func startStderrMonitor(_ pipe: Pipe, generation gen: UInt64) {
        let handle = pipe.fileHandleForReading
        let hostId = host?.id
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty {
                // EOF — pipe closed. Stop monitoring to avoid busy-loop.
                h.readabilityHandler = nil
                return
            }
            guard let s = String(data: data, encoding: .utf8) else { return }
            let msg = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !msg.isEmpty else { return }

            Task { await RemoteLog.shared.log(.debug, "ssh stderr: \(msg)", hostId: hostId) }

            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }

                let lower = msg.lowercased()

                if case .connecting = self.status {
                    // During connecting, only treat known fatal errors as failures.
                    // SSH outputs many informational messages to stderr (host key warnings,
                    // GSSAPI negotiation, banners, etc.) that are not errors.
                    // Real connection failures will cause the process to exit with non-zero,
                    // which is handled by terminationHandler.
                    let isFatalError =
                        lower.contains("permission denied") ||
                        lower.contains("no route to host") ||
                        lower.contains("connection refused") ||
                        lower.contains("connection timed out") ||
                        lower.contains("could not resolve hostname") ||
                        lower.contains("host key verification failed") ||
                        lower.contains("no matching host key") ||
                        lower.contains("remote port forwarding failed") ||
                        lower.contains("remote forwarding") && lower.contains("failed")
                    if isFatalError {
                        self.status = .failed(msg)
                    }
                    return
                }

                if case .connected = self.status {
                    if lower.contains("remote port forwarding failed") ||
                        lower.contains("remote forwarding") && lower.contains("failed") {
                        self.status = .failed(msg)
                    }
                }
            }
        }
    }

    // MARK: - Sandbox SSH Directory (App Store only)

    #if APP_STORE
    nonisolated static func sandboxSSHDir() -> (config: String, knownHosts: String)? {
        let destDir = FileManager.default.temporaryDirectory.appendingPathComponent("vibehub-ssh", isDirectory: true)
        let destConfig = destDir.appendingPathComponent("config")
        let destKnownHosts = destDir.appendingPathComponent("known_hosts")

        let ok: Bool = HookInstaller.withResolvedHome { home -> Bool in
            let fm = FileManager.default
            let srcSSH = home.appendingPathComponent(".ssh")
            let srcConfig = srcSSH.appendingPathComponent("config")
            guard fm.fileExists(atPath: srcConfig.path) else { return false }

            try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)

            try? fm.removeItem(at: destConfig)
            if var configText = try? String(contentsOf: srcConfig, encoding: .utf8) {
                let srcHome = home.path
                configText = configText.replacingOccurrences(of: "~/.ssh/", with: destDir.path + "/")
                configText = configText.replacingOccurrences(of: srcHome + "/.ssh/", with: destDir.path + "/")
                configText = configText.replacingOccurrences(of: "~/Library/", with: srcHome + "/Library/")
                try? configText.write(to: destConfig, atomically: true, encoding: .utf8)
            } else {
                try? fm.copyItem(at: srcConfig, to: destConfig)
            }

            let srcKH = srcSSH.appendingPathComponent("known_hosts")
            if fm.fileExists(atPath: srcKH.path) {
                try? fm.removeItem(at: destKnownHosts)
                try? fm.copyItem(at: srcKH, to: destKnownHosts)
            }

            let keyFiles = ["id_rsa", "id_ed25519", "id_ecdsa", "id_dsa"]
            for keyName in keyFiles {
                for suffix in ["", ".pub"] {
                    let src = srcSSH.appendingPathComponent(keyName + suffix)
                    let dst = destDir.appendingPathComponent(keyName + suffix)
                    if fm.fileExists(atPath: src.path) {
                        try? fm.removeItem(at: dst)
                        try? fm.copyItem(at: src, to: dst)
                        if suffix.isEmpty {
                            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
                        }
                    }
                }
            }

            for subdir in ["config.d", "conf.d"] {
                let src = srcSSH.appendingPathComponent(subdir)
                let dst = destDir.appendingPathComponent(subdir)
                if fm.fileExists(atPath: src.path) {
                    try? fm.removeItem(at: dst)
                    try? fm.copyItem(at: src, to: dst)
                }
            }

            return true
        } ?? false

        guard ok else { return nil }
        return (config: destConfig.path, knownHosts: destKnownHosts.path)
    }
    #endif
}
