import SwiftUI

struct RemoteHostsView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var remoteManager = RemoteManager.shared

    @State private var name: String = ""
    @State private var userAtHost: String = ""
    @State private var port: String = "" // empty => rely on ssh config
    @State private var identityFile: String = ""

    @State private var sshEntries: [SSHConfigEntry] = []
    @State private var showSSHImport: Bool = false
    @State private var sshSearch: String = ""

    private func parseUserHost(_ s: String) -> (user: String?, host: String)? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("@") {
            let parts = trimmed.split(separator: "@", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[1].isEmpty else { return nil }
            let user = parts[0].isEmpty ? nil : parts[0]
            return (user, parts[1])
        }

        // Allow ssh aliases directly (eg "devserver1").
        return (nil, trimmed)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("Remote Hosts")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                Button {
                    viewModel.contentType = .menu
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    if remoteManager.hosts.isEmpty {
                        VStack(spacing: 6) {
                            Text("No remote hosts yet")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white.opacity(0.7))
                            Text("Add one below or import from ~/.ssh/config")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    ForEach(remoteManager.hosts) { host in
                        let status = remoteManager.connectionStatus[host.id] ?? .disconnected
                        let report = remoteManager.lastInstallReport[host.id]
                        let installing = remoteManager.installRunning[host.id] ?? false
                        let startedAt = remoteManager.installStartedAt[host.id]
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.92))
                                Text(hostLine(for: host))
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.45))

                                Text("id: \(String(host.id.prefix(8)))  sock: \(host.localSocketPath)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.35))

                                Text(statusLine(for: status))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(statusColor(for: status))

                                if let report {
                                    Text(report.ok ? "Install OK" : "Install needs attention")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(report.ok ? TerminalColors.green : Color(red: 1.0, green: 0.7, blue: 0.35))
                                } else if installing {
                                    Text("Installing...\(installAgeText(startedAt))")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(TerminalColors.blue)
                                } else if case .connected = status {
                                    Text("Install not started")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.35))
                                }
                            }

                            Spacer()

                            Button {
                                switch status {
                                case .connected, .connecting:
                                    remoteManager.disconnect(id: host.id)
                                case .disconnected, .failed:
                                    remoteManager.connect(id: host.id)
                                }
                            } label: {
                                Text(buttonLabel(for: status))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Color.white.opacity(0.92))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled({
                                if case .connecting = status { return true }
                                return false
                            }())

                            Button {
                                remoteManager.removeHost(id: host.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.5))
                                    .frame(width: 28, height: 28)
                                    .background(Color.white.opacity(0.06))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        if case .failed(let msg) = status {
                            Text(msg)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                        }

                        if installing {
                            Text("Installing remote hooks/plugins...")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 6)
                        }

                        if let report, !report.ok {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Install log")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.6))
                                ForEach(report.steps.prefix(6)) { step in
                                    let line = "\(step.ok ? "ok" : "fail") \(step.name) (\(step.exitCode))"
                                    Text(line)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(step.ok ? .white.opacity(0.45) : Color(red: 1.0, green: 0.55, blue: 0.55))
                                }
                                if report.steps.count > 6 {
                                    Text("...")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.35))
                                }

                                if let bad = report.steps.first(where: { !$0.ok }) {
                                    if !bad.command.isEmpty {
                                        Text(bad.command)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.45))
                                            .lineLimit(2)
                                    }
                                    if !bad.stderr.isEmpty {
                                        Text(bad.stderr)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.55))
                                            .lineLimit(10)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 6)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            Divider()
                .background(Color.white.opacity(0.08))

            VStack(spacing: 8) {
                HStack {
                    Button {
                        sshEntries = SSHConfigParser.loadUserConfig()
                        sshSearch = ""
                        showSSHImport = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "terminal")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Import from SSH config")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }

                HStack(spacing: 8) {
                    TextField("Name", text: $name)
                    TextField("user@host", text: $userAtHost)
                }
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                HStack(spacing: 8) {
                    TextField("Port", text: $port)
                        .frame(width: 70)
                    TextField("Identity file (optional)", text: $identityFile)
                }
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Button {
                    guard let parsed = parseUserHost(userAtHost) else { return }
                    let host = RemoteHost(
                        name: name.isEmpty ? parsed.host : name,
                        user: parsed.user,
                        host: parsed.host,
                        port: portValue,
                        identityFile: identityFile.isEmpty ? nil : identityFile
                    )
                    remoteManager.addHost(host)
                    name = ""
                    userAtHost = ""
                    port = ""
                    identityFile = ""
                } label: {
                    Text("Add")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Color.white.opacity(0.92))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(parseUserHost(userAtHost) == nil)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if showSSHImport {
                sshImportOverlay
            }
        }
    }

    private var sshImportOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { showSSHImport = false }

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Text("~/.ssh/config")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                    Spacer()
                    Button {
                        showSSHImport = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                            .frame(width: 24, height: 24)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                TextField("Search", text: $sshSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        if filteredSSHEntries.isEmpty {
                            Text(sshEntries.isEmpty ? "No entries found" : "No matches")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white.opacity(0.55))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 18)
                        }

                        ForEach(filteredSSHEntries) { e in
                            Button {
                                // Fill the form; let the user adjust before adding.
                                // Prefer explicit user; otherwise default to the current local username.
                                // Prefer the ssh alias so additional options (ProxyJump, etc) apply.
                                // If the entry includes a User, keep it; otherwise allow alias-only.
                                let user = e.user?.trimmingCharacters(in: .whitespacesAndNewlines)
                                if let user, !user.isEmpty {
                                    userAtHost = "\(user)@\(e.alias)"
                                } else {
                                    userAtHost = e.alias
                                }
                                name = e.alias
                                port = String(e.port ?? 22)
                                identityFile = e.identityFile ?? ""
                                showSSHImport = false
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(e.alias)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.92))
                                        Text(detailLine(for: e))
                                            .font(.system(size: 11))
                                            .foregroundColor(.white.opacity(0.45))
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.down.left")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.35))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 420, height: 320)
            .background(Color.black.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
        }
    }

    private var filteredSSHEntries: [SSHConfigEntry] {
        let q = sshSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return sshEntries }
        return sshEntries.filter { e in
            e.alias.lowercased().contains(q) ||
            (e.hostName?.lowercased().contains(q) ?? false) ||
            (e.user?.lowercased().contains(q) ?? false)
        }
    }

    private func detailLine(for e: SSHConfigEntry) -> String {
        let host = e.hostName ?? e.alias
        let user = e.user ?? "(no user)"
        let port = e.port.map(String.init) ?? "(default)"
        return "\(user)@\(host):\(port)"
    }

    private func installAgeText(_ startedAt: Date?) -> String {
        guard let startedAt else { return "" }
        let secs = Int(Date().timeIntervalSince(startedAt))
        if secs <= 0 { return "" }
        return " \(secs)s"
    }

    private var portValue: Int? {
        let t = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return Int(t)
    }

    private func hostLine(for host: RemoteHost) -> String {
        if let port = host.port {
            return "\(host.sshTarget):\(port)"
        }
        return "\(host.sshTarget) (ssh config)"
    }

    private func buttonLabel(for status: SSHForwarder.Status) -> String {
        switch status {
        case .disconnected:
            return "Connect"
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Disconnect"
        case .failed:
            return "Retry"
        }
    }

    private func statusLine(for status: SSHForwarder.Status) -> String {
        switch status {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .failed:
            return "Failed"
        }
    }

    private func statusColor(for status: SSHForwarder.Status) -> Color {
        switch status {
        case .connected:
            return TerminalColors.green
        case .connecting:
            return TerminalColors.blue
        case .failed:
            return Color(red: 1.0, green: 0.4, blue: 0.4)
        case .disconnected:
            return .white.opacity(0.35)
        }
    }
}
