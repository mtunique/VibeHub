import SwiftUI

struct RemoteHostsView: View {
    var viewModel: NotchViewModel?
    @ObservedObject private var remoteManager = RemoteManager.shared

    @State private var name: String = ""
    @State private var userAtHost: String = ""
    @State private var port: String = "" // empty => rely on ssh config
    @State private var identityFile: String = ""
    @State private var useGSSAPI: Bool = false

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
                Text(L10n.remoteHosts)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.9))
                Spacer()
                Button {
                    viewModel?.contentType = .menu
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.primary.opacity(0.6))
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.08))
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
                            Text(L10n.noRemoteHostsYet)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.primary.opacity(0.7))
                            Text(L10n.addOrImportSSH)
                                .font(.system(size: 11))
                                .foregroundColor(.primary.opacity(0.45))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(Color.primary.opacity(0.04))
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
                                    .foregroundColor(.primary.opacity(0.92))
                                Text(hostLine(for: host))
                                    .font(.system(size: 11))
                                    .foregroundColor(.primary.opacity(0.45))

                                Text("id: \(String(host.id.prefix(8)))  sock: \(host.localSocketPath)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.primary.opacity(0.35))

                                Text(statusLine(for: status))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(statusColor(for: status))

                                if let report {
                                    Text(report.ok ? L10n.installOK : L10n.installNeedsAttention)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(report.ok ? TerminalColors.green : Color(red: 1.0, green: 0.7, blue: 0.35))
                                } else if installing {
                                    Text("\(L10n.installing)\(installAgeText(startedAt))")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(TerminalColors.blue)
                                } else if case .connected = status {
                                    Text(L10n.installNotStarted)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.primary.opacity(0.35))
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
                                    .foregroundColor(Color(nsColor: .textBackgroundColor))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Color.primary.opacity(0.92))
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
                                    .foregroundColor(.primary.opacity(0.5))
                                    .frame(width: 28, height: 28)
                                    .background(Color.primary.opacity(0.06))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        if case .failed(let msg) = status {
                            Text(msg)
                                .font(.system(size: 11))
                                .foregroundColor(.primary.opacity(0.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                        }

                        if installing {
                            Text(L10n.installingRemoteHooks)
                                .font(.system(size: 11))
                                .foregroundColor(.primary.opacity(0.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 6)
                        }

                        if let report, !report.ok {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.installLog)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.primary.opacity(0.6))
                                // Show ok steps (compact), then all failed steps explicitly
                                let okSteps = report.steps.filter { $0.ok }
                                let failedSteps = report.steps.filter { !$0.ok }
                                ForEach(okSteps.prefix(6)) { step in
                                    Text("ok \(step.name) (\(step.exitCode))")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.primary.opacity(0.45))
                                }
                                if okSteps.count > 6 {
                                    Text("... +\(okSteps.count - 6) ok")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.primary.opacity(0.35))
                                }
                                ForEach(failedSteps) { step in
                                    Text("FAIL \(step.name) (exit \(step.exitCode))")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(Color(red: 1.0, green: 0.55, blue: 0.55))
                                }

                                if let bad = failedSteps.first {
                                    if !bad.command.isEmpty {
                                        Text(bad.command)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.primary.opacity(0.45))
                                            .lineLimit(2)
                                    }
                                    if !bad.stderr.isEmpty {
                                        Text(bad.stderr)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.primary.opacity(0.55))
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
                .background(Color.primary.opacity(0.08))

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
                            Text(L10n.importFromSSHConfig)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.primary.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color.primary.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }

                HStack(spacing: 8) {
                    TextField(L10n.name, text: $name)
                    TextField(L10n.userAtHost, text: $userAtHost)
                }
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                HStack(spacing: 8) {
                    TextField(L10n.port, text: $port)
                        .frame(width: 70)
                    TextField(L10n.identityFileOptional, text: $identityFile)
                }
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // GSSAPI toggle
                HStack(spacing: 10) {
                    Toggle(isOn: $useGSSAPI) {
                        Text("Use GSSAPI authentication")
                            .font(.system(size: 12))
                            .foregroundColor(.primary.opacity(0.7))
                    }
                    .toggleStyle(.switch)
                    .scaleEffect(0.7)
                    Spacer()
                    Text("For jump hosts")
                        .font(.system(size: 10))
                        .foregroundColor(.primary.opacity(0.4))
                }
                .padding(.horizontal, 12)

                Button {
                    guard let parsed = parseUserHost(userAtHost) else { return }
                    let host = RemoteHost(
                        name: name.isEmpty ? parsed.host : name,
                        user: parsed.user,
                        host: parsed.host,
                        port: portValue,
                        identityFile: identityFile.isEmpty ? nil : identityFile,
                        useGSSAPI: useGSSAPI
                    )
                    remoteManager.addHost(host)
                    name = ""
                    userAtHost = ""
                    port = ""
                    identityFile = ""
                    useGSSAPI = false
                } label: {
                    Text(L10n.add)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(nsColor: .textBackgroundColor))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Color.primary.opacity(0.92))
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
            Color.primary.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { showSSHImport = false }

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Text(L10n.sshConfig)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.9))
                    Spacer()
                    Button {
                        showSSHImport = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.primary.opacity(0.6))
                            .frame(width: 24, height: 24)
                            .background(Color.primary.opacity(0.08))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                TextField(L10n.search, text: $sshSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        if filteredSSHEntries.isEmpty {
                            Text(sshEntries.isEmpty ? L10n.noEntriesFound : L10n.noMatches)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.primary.opacity(0.55))
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
                                useGSSAPI = e.useGSSAPI
                                showSSHImport = false
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(e.alias)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.primary.opacity(0.92))
                                        Text(detailLine(for: e))
                                            .font(.system(size: 11))
                                            .foregroundColor(.primary.opacity(0.45))
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.down.left")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.primary.opacity(0.35))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.primary.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 420, height: 320)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
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
        let user = e.user ?? L10n.noUser
        let port = e.port.map(String.init) ?? L10n.defaultPort
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
        return "\(host.sshTarget) \(L10n.sshConfigSuffix)"
    }

    private func buttonLabel(for status: SSHForwarder.Status) -> String {
        switch status {
        case .disconnected:
            return L10n.connect
        case .connecting:
            return L10n.connecting
        case .connected:
            return L10n.disconnect
        case .failed:
            return L10n.retry
        }
    }

    private func statusLine(for status: SSHForwarder.Status) -> String {
        switch status {
        case .disconnected:
            return L10n.disconnected
        case .connecting:
            return L10n.connectingStatus
        case .connected:
            return L10n.connected
        case .failed:
            return L10n.failed
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
            return .primary.opacity(0.35)
        }
    }
}
