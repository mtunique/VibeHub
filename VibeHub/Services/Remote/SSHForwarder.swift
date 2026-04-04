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
        let cmd = ([sshPath] + args)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")

        let p = Process()
        // Run via login shell so ssh sees same auth env as Terminal.
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        p.environment = RemoteInstaller.getSSHEnvironment()

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
                    // If ControlMaster=auto exited with 0, we are actually connected via multiplexing
                    if p.terminationStatus == 0 {
                        self.status = .connected
                    } else {
                        self.status = .failed("ssh exited (\(p.terminationStatus))")
                    }
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

        args += [
            "-N",
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-o", "StreamLocalBindUnlink=yes",
            // Make the remote unix socket connectable by the actual CLI process user.
            // Default is 0177 (srw-------) which often breaks hooks.
            "-o", "StreamLocalBindMask=0000",
        ]

        // Sandbox: SSH child processes cannot read ~/.ssh/config through the
        // security-scoped bookmark. Copy the config into the container so SSH
        // can read it via -F.
        #if APP_STORE
        if let ssh = Self.sandboxSSHDir() {
            args += ["-F", ssh.config]
            args += ["-o", "UserKnownHostsFile=\(ssh.knownHosts)"]
        }
        #endif

        // ControlMaster socket. Sandbox cannot create Unix sockets in /tmp
        // (Operation not permitted), and container paths exceed the 104-byte
        // sun_path limit, so disable ControlMaster entirely in App Store builds.
        #if APP_STORE
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

        // GSSAPI authentication for jump hosts, Kerberos environments, etc.
        if host.useGSSAPI {
            // Using PreferredAuthentications forces gssapi-with-mic first,
            // avoiding the intermittent "Miscellaneous failure" that occurs
            // when SSH tries gssapi-with-mic alongside other methods.
            args += ["-o", "PreferredAuthentications=gssapi-with-mic"]
        }

        if let port = host.port {
            args += ["-p", String(port)]
        }

        #if !APP_STORE
        if let key = host.identityFile, !key.isEmpty {
            args += ["-i", key]
        }
        #endif

        // Remote unix socket -> local unix socket
        args += ["-R", "\(host.remoteSocketPath):\(host.localSocketPath)"]
        args += [host.sshTarget]
        return args
    }

    #if APP_STORE
    /// Mirrors essential ~/.ssh/ files into the sandbox container so SSH child
    /// processes can access them. Returns (configPath, knownHostsPath) or nil.
    /// Uses the container tmp dir (no spaces) because SSH treats spaces in
    /// UserKnownHostsFile as path separators.
    nonisolated static func sandboxSSHDir() -> (config: String, knownHosts: String)? {
        let destDir = FileManager.default.temporaryDirectory.appendingPathComponent("vibehub-ssh", isDirectory: true)
        let destConfig = destDir.appendingPathComponent("config")
        let destKnownHosts = destDir.appendingPathComponent("known_hosts")

        // Copy from real home using security-scoped bookmark.
        let ok: Bool = HookInstaller.withResolvedHome { home -> Bool in
            let fm = FileManager.default
            let srcSSH = home.appendingPathComponent(".ssh")
            let srcConfig = srcSSH.appendingPathComponent("config")
            guard fm.fileExists(atPath: srcConfig.path) else { return false }

            try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)

            // config — copy then rewrite IdentityFile/IdentityAgent paths
            // so SSH child processes can find keys inside the container.
            try? fm.removeItem(at: destConfig)
            if var configText = try? String(contentsOf: srcConfig, encoding: .utf8) {
                // Rewrite ~/.<path> and ~/<path> references to point at the container copy.
                let srcHome = home.path  // e.g. /Users/mtunique
                configText = configText.replacingOccurrences(of: "~/.ssh/", with: destDir.path + "/")
                configText = configText.replacingOccurrences(of: srcHome + "/.ssh/", with: destDir.path + "/")
                // Rewrite IdentityAgent paths that reference the real home
                configText = configText.replacingOccurrences(of: "~/Library/", with: srcHome + "/Library/")
                try? configText.write(to: destConfig, atomically: true, encoding: .utf8)
            } else {
                try? fm.copyItem(at: srcConfig, to: destConfig)
            }

            // known_hosts
            let srcKH = srcSSH.appendingPathComponent("known_hosts")
            if fm.fileExists(atPath: srcKH.path) {
                try? fm.removeItem(at: destKnownHosts)
                try? fm.copyItem(at: srcKH, to: destKnownHosts)
            }

            // Copy key files (id_rsa, id_ed25519, etc.) so SSH can load them.
            let keyFiles = ["id_rsa", "id_ed25519", "id_ecdsa", "id_dsa"]
            for keyName in keyFiles {
                for suffix in ["", ".pub"] {
                    let src = srcSSH.appendingPathComponent(keyName + suffix)
                    let dst = destDir.appendingPathComponent(keyName + suffix)
                    if fm.fileExists(atPath: src.path) {
                        try? fm.removeItem(at: dst)
                        try? fm.copyItem(at: src, to: dst)
                    }
                }
            }

            // Include sub-directories (config.d, conf.d)
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

                // During connect, treat stderr as failure (eg Permission denied),
                // but ignore local forwarding noise from the user's ~/.ssh/config
                // (eg "bind: Address already in use", "cannot listen to port").
                if case .connecting = self.status {
                    let lower = msg.lowercased()
                    let isLocalForwardNoise =
                        lower.contains("address already in use") ||
                        lower.contains("cannot listen to port") ||
                        lower.contains("channel_setup_fwd_listener_tcpip") ||
                        lower.contains("could not request local forwarding")
                    if !isLocalForwardNoise {
                        self.status = .failed(msg)
                    }
                    return
                }

                // When already connected, ignore benign ssh noise (eg known_hosts warnings)
                // and local forwarding failures (from the user's ~/.ssh/config LocalForward
                // directives). Only fail on REMOTE forwarding errors which affect our -R tunnel.
                if case .connected = self.status {
                    let lower = msg.lowercased()
                    if lower.contains("remote port forwarding failed") ||
                        lower.contains("remote forwarding") && lower.contains("failed") {
                        self.status = .failed(msg)
                    }
                }
            }
        }
    }
}
