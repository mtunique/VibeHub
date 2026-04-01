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

    func connect(host: RemoteHost) {
        disconnect()
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
                if case .disconnected = self.status { return }
                let code = proc.terminationStatus
                self.status = .failed("ssh exited (\(code))")
            }
        }

        do {
            try p.run()
            process = p
            // Only mark connected after we know the process is alive.
            status = .connecting
            startStderrMonitor(err)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak p] in
                guard let self else { return }
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
        status = .disconnected
    }

    private func buildArgs(host: RemoteHost) -> [String] {
        var args: [String] = []

        args += [
            "-N",
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "StreamLocalBindUnlink=yes",
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

    private func startStderrMonitor(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                let msg = s.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !msg.isEmpty else { return }

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
