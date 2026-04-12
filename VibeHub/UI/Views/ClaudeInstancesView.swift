//
//  ClaudeInstancesView.swift
//  VibeHub
//
//  Minimal instances list matching Dynamic Island aesthetic
//

import Combine
import SwiftUI

struct ClaudeInstancesView: View {
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        if sessionMonitor.instances.isEmpty {
            emptyState
        } else {
            instancesList
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(L10n.noSessions)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary.opacity(0.4))

            Text(L10n.runClaudeInTerminal)
                .font(.system(size: 11))
                .foregroundColor(.primary.opacity(0.25))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Instances List

    /// Priority: active (approval/processing/compacting) > waitingForInput > idle
    /// Secondary sort: by last user message date (stable - doesn't change when agent responds)
    /// Note: approval requests stay in their date-based position to avoid layout shift
    private var sortedInstances: [SessionState] {
        sessionMonitor.instances.sorted { a, b in
            let priorityA = phasePriority(a.phase)
            let priorityB = phasePriority(b.phase)
            if priorityA != priorityB {
                return priorityA < priorityB
            }
            // Sort by last user message date (more recent first)
            // Fall back to lastActivity if no user messages yet
            let dateA = a.lastUserMessageDate ?? a.lastActivity
            let dateB = b.lastUserMessageDate ?? b.lastActivity
            return dateA > dateB
        }
    }

    /// Lower number = higher priority
    /// Approval requests share priority with processing to maintain stable ordering
    private func phasePriority(_ phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval, .processing, .compacting: return 0
        case .waitingForInput: return 1
        case .idle, .ended: return 2
        }
    }

    private var instancesList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 2) {
                ForEach(sortedInstances) { session in
                    InstanceRow(
                        session: session,
                        onFocus: { focusSession(session) },
                        onChat: { openChat(session) },
                        onArchive: { archiveSession(session) },
                        onApprove: { approveSession(session) },
                        onApproveAlways: { approveSessionAlways(session) },
                        onReject: { rejectSession(session) }
                    )
                    .id(session.stableId)
                }
            }
            .padding(.vertical, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Actions

    private func focusSession(_ session: SessionState) {
        let msg = "focusSession: pid=\(session.pid ?? -1)\n"
        FileManager.default.createFile(atPath: "/tmp/vibehub-activator.log", contents: msg.data(using: .utf8))
        viewModel.notchClose()
        Task {
            await TerminalActivator.shared.activateTerminal(for: session)
        }
    }

    private func openChat(_ session: SessionState) {
        viewModel.showChat(for: session)
    }

    private func approveSession(_ session: SessionState) {
        sessionMonitor.approvePermission(sessionId: session.sessionId)
    }

    private func approveSessionAlways(_ session: SessionState) {
        sessionMonitor.approvePermissionAlways(sessionId: session.sessionId)
    }

    private func rejectSession(_ session: SessionState) {
        sessionMonitor.denyPermission(sessionId: session.sessionId, reason: nil)
    }

    private func archiveSession(_ session: SessionState) {
        sessionMonitor.archiveSession(sessionId: session.sessionId)
    }
}

// MARK: - Instance Row

struct InstanceRow: View {
    let session: SessionState
    let onFocus: () -> Void
    let onChat: () -> Void
    let onArchive: () -> Void
    let onApprove: () -> Void
    let onApproveAlways: () -> Void
    let onReject: () -> Void

    @State private var isHovered = false
    @State private var spinnerPhase = 0
    private let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
    private let spinnerSymbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    private let spinnerTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    /// Whether we're showing the approval UI
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    /// Whether the pending tool requires interactive input (not just approve/deny)
    private var isInteractiveTool: Bool {
        guard let toolName = session.pendingToolName else { return false }
        return toolName == "AskUserQuestion"
    }

    /// Whether the approval UI should show an "Always" option
    private var allowAlways: Bool {
        true
    }

    /// Display name of the remote host, if this is a remote session
    private var remoteHostName: String? {
        guard let hostId = session.remoteHostId else { return nil }
        return RemoteManager.shared.hosts.first(where: { $0.id == hostId })?.name
            ?? hostId.prefix(8).description
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // First row: indicator, title, and tags
            HStack(alignment: .center, spacing: 10) {
                // State indicator on left
                stateIndicator
                    .frame(width: 14)

                Text(session.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                // Tags: software label + remote host + time
                HStack(spacing: 6) {
                    // Software tag (Claude/OpenCode/Codex)
                    let sourceColor: Color = {
                        switch session.cliSource {
                        case .claude: return claudeOrange
                        case .opencode: return TerminalColors.green
                        case .codex: return TerminalColors.blue
                        }
                    }()
                    Text(session.cliSource.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(sourceColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(sourceColor.opacity(0.15))
                        .clipShape(Capsule())

                    // Remote host tag
                    if let hostName = remoteHostName {
                        Text(hostName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(TerminalColors.cyan)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(TerminalColors.cyan.opacity(0.15))
                            .clipShape(Capsule())
                    }

                    // Time tag
                    Text(formatTimeAgo(session.lastActivity))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.4))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }
            }

            // Second row: description
            HStack(spacing: 4) {
                if isWaitingForApproval, let toolName = session.pendingToolName {
                    Text(MCPToolFormatter.formatToolName(toolName))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(TerminalColors.amber.opacity(0.9))
                        .fixedSize()
                    if isInteractiveTool {
                        Text(L10n.needsYourInput)
                            .font(.system(size: 11))
                            .foregroundColor(.primary.opacity(0.5))
                            .lineLimit(1)
                    } else if let input = session.pendingToolInput {
                        MarqueeText(
                            text: input,
                            fontSize: 11,
                            fontWeight: .regular,
                            nsFontWeight: .regular,
                            color: .primary.opacity(0.5),
                            trigger: input,
                            loop: true
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 14)
                    }
                } else if let role = session.lastMessageRole {
                    switch role {
                    case "tool":
                        if let toolName = session.lastToolName {
                            Text(MCPToolFormatter.formatToolName(toolName))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.primary.opacity(0.5))
                                .fixedSize()
                        }
                        if let input = session.lastMessage {
                            Text(input)
                                .font(.system(size: 11))
                                .foregroundColor(.primary.opacity(0.4))
                                .lineLimit(1)
                        }
                    case "user":
                        Text(L10n.you)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.primary.opacity(0.5))
                            .fixedSize()
                        if let msg = session.lastMessage {
                            Text(msg)
                                .font(.system(size: 11))
                                .foregroundColor(.primary.opacity(0.4))
                                .lineLimit(1)
                        }
                    default:
                        if let msg = session.lastMessage {
                            Text(msg)
                                .font(.system(size: 11))
                                .foregroundColor(.primary.opacity(0.4))
                                .lineLimit(1)
                        }
                    }
                } else if let lastMsg = session.lastMessage {
                    Text(lastMsg)
                        .font(.system(size: 11))
                        .foregroundColor(.primary.opacity(0.4))
                        .lineLimit(1)
                }
            }
            .padding(.leading, 24)

            // Third row: action buttons (separate row for approval)
            HStack(spacing: 8) {
                Spacer(minLength: 0)

                if isWaitingForApproval && isInteractiveTool {
                    IconButton(icon: "bubble.left", tooltip: L10n.openChat) {
                        onChat()
                    }
                    if session.pid != nil || session.isRemote {
                        TerminalButton(
                            isEnabled: true,
                            onTap: { onFocus() }
                        )
                        .help(L10n.revealInTerminal)
                    }
                } else if isWaitingForApproval {
                    InlineApprovalButtons(
                        onChat: onChat,
                        onApprove: onApprove,
                        onReject: onReject,
                        allowAlways: allowAlways,
                        onAlways: allowAlways ? onApproveAlways : nil
                    )
                } else {
                    IconButton(icon: "bubble.left", tooltip: L10n.openChat) {
                        onChat()
                    }
                    if session.pid != nil || session.isRemote {
                        IconButton(icon: "eye", tooltip: L10n.revealInTerminal) {
                            onFocus()
                        }
                    }
                    if session.phase == .idle || session.phase == .waitingForInput {
                        IconButton(icon: "archivebox", tooltip: L10n.archiveSession) {
                            onArchive()
                        }
                    }
                }
            }
            .padding(.leading, 24)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onChat()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isWaitingForApproval)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch session.phase {
        case .processing, .compacting:
            Text(spinnerSymbols[spinnerPhase % spinnerSymbols.count])
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(claudeOrange)
                .onReceive(spinnerTimer) { _ in
                    spinnerPhase = (spinnerPhase + 1) % spinnerSymbols.count
                }
        case .waitingForApproval:
            Text(spinnerSymbols[spinnerPhase % spinnerSymbols.count])
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(TerminalColors.amber)
                .onReceive(spinnerTimer) { _ in
                    spinnerPhase = (spinnerPhase + 1) % spinnerSymbols.count
                }
        case .waitingForInput:
            Circle()
                .fill(TerminalColors.green)
                .frame(width: 6, height: 6)
        case .idle, .ended:
            Circle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 6, height: 6)
        }
    }

    private func formatTimeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "\(Int(interval))s" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86400))d"
    }
}

// MARK: - Inline Approval Buttons

/// Compact inline approval buttons with staggered animation
struct InlineApprovalButtons: View {
    let onChat: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void
    let allowAlways: Bool
    let onAlways: (() -> Void)?

    @Environment(\.isNotchMode) private var isNotchMode
    @State private var showChatButton = false
    @State private var showDenyButton = false
    @State private var showAllowButton = false
    @State private var showAlwaysButton = false

    var body: some View {
        HStack(spacing: 6) {
            // Chat button
            IconButton(icon: "bubble.left", tooltip: L10n.openChat) {
                onChat()
            }
            .opacity(showChatButton ? 1 : 0)
            .scaleEffect(showChatButton ? 1 : 0.8)

            Button {
                onReject()
            } label: {
                Text(L10n.deny)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .opacity(showDenyButton ? 1 : 0)
            .scaleEffect(showDenyButton ? 1 : 0.8)

            if allowAlways {
                Button {
                    onAlways?()
                } label: {
                    Text(L10n.always)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary.opacity(0.75))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.14))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .opacity(showAlwaysButton ? 1 : 0)
                .scaleEffect(showAlwaysButton ? 1 : 0.8)
            }

            Button {
                onApprove()
            } label: {
                Text(L10n.allow)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isNotchMode ? .black : .white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(isNotchMode ? Color.white.opacity(0.9) : Color.accentColor)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .opacity(showAllowButton ? 1 : 0)
            .scaleEffect(showAllowButton ? 1 : 0.8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.0)) {
                showChatButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showDenyButton = true
            }
            if allowAlways {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.1)) {
                    showAlwaysButton = true
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.15)) {
                    showAllowButton = true
                }
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.1)) {
                    showAllowButton = true
                }
            }
        }
    }
}

// MARK: - Icon Button

struct IconButton: View {
    let icon: String
    var tooltip: String? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isHovered ? .primary.opacity(0.8) : .primary.opacity(0.4))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tooltip ?? "")
    }
}

// MARK: - Compact Terminal Button (inline in description)

struct CompactTerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "terminal")
                    .font(.system(size: 8, weight: .medium))
                Text(L10n.goToTerminal)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isEnabled ? .primary.opacity(0.9) : .primary.opacity(0.3))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isEnabled ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Terminal Button

struct TerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    @Environment(\.isNotchMode) private var isNotchMode

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .medium))
                Text(L10n.terminal)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor({
                if !isEnabled {
                    return isNotchMode ? Color.white.opacity(0.4) : Color.primary.opacity(0.4)
                }
                return isNotchMode ? .black : .white
            }())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background({
                if !isEnabled {
                    return Color.white.opacity(0.1)
                }
                return isNotchMode ? Color.white.opacity(0.95) : Color.accentColor
            }())
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
