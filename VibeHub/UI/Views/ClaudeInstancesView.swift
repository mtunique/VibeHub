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
    @State private var isConclusionHovered = false
    /// Pending "start expanding the conclusion block" work. Scheduled on
    /// hover-in with a ~0.5s delay (hover-intent) so the block doesn't
    /// jitter as the pointer sweeps across the list.
    @State private var conclusionExpandWork: DispatchWorkItem?
    /// Pending "collapse the conclusion block" work. Scheduled on hover-out
    /// with a small delay so transient hover-exit events (e.g. when the
    /// block grows during expansion and SwiftUI briefly loses the pointer
    /// over the old bounds) don't cause immediate collapse.
    @State private var conclusionCollapseWork: DispatchWorkItem?
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

    /// Final assistant reply to display in the "conclusion" block when the
    /// session has finished its turn.
    ///
    /// We walk `session.chatItems` backward FIRST — those entries hold the
    /// full, non-truncated assistant text straight from JSONL / SQLite.
    /// Only fall back to `session.conversationInfo.lastMessage` when the
    /// chat items haven't been hydrated yet (truncated to 80 chars by the
    /// parser). The `lastMessageRole == "assistant"` check is deliberately
    /// skipped because ConversationParser marks a trailing tool_use block
    /// as `role == "tool"`, which would hide the preceding assistant text.
    private var finalConclusion: String? {
        for item in session.chatItems.reversed() {
            if case .assistant(let text) = item.type {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        if let last = session.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !last.isEmpty,
           session.lastMessageRole != "user",
           session.lastMessageRole != "tool" {
            return last
        }
        return nil
    }

    /// True when we should render the highlighted conclusion block in place
    /// of the regular description row. `.waitingForInput` is the obvious
    /// trigger; `.idle` is also covered so sessions that have been sitting
    /// around after finishing still show their final reply.
    private var showConclusion: Bool {
        switch session.phase {
        case .waitingForInput, .idle:
            return finalConclusion != nil
        default:
            return false
        }
    }

    /// Description line built as one concatenated Text so the leading label
    /// (tool name / "You") and the trailing content share a single text
    /// run. Line 2 therefore gets the full row width instead of the narrow
    /// "content column" an HStack split would give it — long bash commands
    /// no longer tail-truncate prematurely.
    @ViewBuilder
    private var descriptionRow: some View {
        if isWaitingForApproval, let toolName = session.pendingToolName {
            // Amber is kept here as an attention color — the state
            // indicator is already amber while waiting for approval,
            // so tool name + state match visually.
            let label = Text(MCPToolFormatter.formatToolName(toolName))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(TerminalColors.amber.opacity(0.9))

            if isInteractiveTool {
                (label + Text("  ") + Text(L10n.needsYourInput)
                    .font(.system(size: 11))
                    .foregroundColor(.primary.opacity(0.5)))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            } else {
                label
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let role = session.lastMessageRole {
            switch role {
            case "tool":
                // Tool label + formatted input on a single Text so wrapping
                // uses the full row width on both lines.
                let tail = session.lastMessage ?? ""
                let toolName = session.lastToolName ?? ""
                let labeled = Text(MCPToolFormatter.formatToolName(toolName))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(MCPToolFormatter.color(for: toolName))
                (labeled
                    + Text(tail.isEmpty ? "" : "  ")
                    + Text(tail)
                        .font(.system(size: 11))
                        .foregroundColor(.primary.opacity(0.4)))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case "user":
                let tail = session.lastMessage ?? ""
                let labeled = Text(L10n.you)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary.opacity(0.5))
                (labeled
                    + Text(tail.isEmpty ? "" : "  ")
                    + Text(tail)
                        .font(.system(size: 11))
                        .foregroundColor(.primary.opacity(0.4)))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            default:
                if let msg = session.lastMessage {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundColor(.primary.opacity(0.4))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else if let lastMsg = session.lastMessage {
            Text(lastMsg)
                .font(.system(size: 11))
                .foregroundColor(.primary.opacity(0.4))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Parse the conclusion text as inline markdown into an `AttributedString`
    /// so SwiftUI's native `Text` can render `**bold**`, `*italic*`, `` `code` ``,
    /// and links while still respecting `.lineLimit`. Uses
    /// `.inlineOnlyPreservingWhitespace` so paragraph breaks survive.
    /// Falls back to the raw text on any parse failure.
    private func conclusionAttributedString(_ text: String) -> AttributedString {
        do {
            return try AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )
        } catch {
            return AttributedString(text)
        }
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
                    // Software tag (Claude / OpenCode / Codex / fork).
                    // Label + color come from SupportedCLI so any new CLI
                    // in CLIConfig.all automatically gets a tag.
                    let sourceColor = session.source.themeColor
                    Text(session.source.displayName)
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

            // When the session has finished its turn and is waiting on the
            // user, surface the assistant's final reply as a dedicated
            // "conclusion" block with its own ScrollView so:
            //  - expansion never grows the outer instances list (long
            //    conclusions scroll inside the block, not the row)
            //  - on collapse the ScrollViewReader jumps the inner scroll
            //    back to the top so the 90pt preview always shows the
            //    first lines regardless of where the user stopped.
            if showConclusion, let conclusion = finalConclusion {
                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical, showsIndicators: isConclusionHovered) {
                        MarkdownText(
                            conclusion,
                            color: .primary.opacity(0.85),
                            fontSize: 11
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .id("conclusion-top")
                    }
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: isConclusionHovered ? 240 : 90,
                        alignment: .topLeading
                    )
                    .clipped()
                    .onChange(of: isConclusionHovered) { _, hovered in
                        // Defer the scroll reset to the next runloop tick so
                        // it never fires during the collapse layout pass
                        // (that combo was the crash risk).
                        guard !hovered else { return }
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                scrollProxy.scrollTo("conclusion-top", anchor: .top)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(TerminalColors.green.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(TerminalColors.green.opacity(0.25), lineWidth: 0.5)
                        )
                )
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
                .onHover { hovering in
                    // Hover intent: expand only if the pointer stays on the
                    // block for ~0.55s, so sweeping over the instances list
                    // doesn't cause conclusions to flicker open and closed.
                    // Collapse is also debounced by a short window (0.2s)
                    // because the layout grows on expansion, and SwiftUI
                    // can briefly report hover=false while the new, larger
                    // child view is being laid out — without the debounce
                    // the block would oscillate between collapsed and
                    // expanded.
                    if hovering {
                        conclusionCollapseWork?.cancel()
                        conclusionCollapseWork = nil
                        if isConclusionHovered {
                            return
                        }
                        conclusionExpandWork?.cancel()
                        let work = DispatchWorkItem {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isConclusionHovered = true
                            }
                        }
                        conclusionExpandWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
                    } else {
                        // Cancel any pending expansion so leaving before the
                        // 0.55s mark aborts the expand entirely.
                        conclusionExpandWork?.cancel()
                        conclusionExpandWork = nil

                        // Debounce the actual collapse so a transient
                        // hover-exit during the expansion animation doesn't
                        // snap the block closed.
                        conclusionCollapseWork?.cancel()
                        let work = DispatchWorkItem {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isConclusionHovered = false
                            }
                        }
                        conclusionCollapseWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            } else {
            // Second row: description. Built from Text(+) concatenation so
            // the leading label (tool name / "You") and the trailing content
            // live in a single Text view — wrapping then uses the full
            // row width for both lines, instead of the narrow "content
            // column" an HStack split would give us (which was cutting off
            // line 2 with an early ellipsis).
            descriptionRow
                .padding(.leading, 24)
            } // end: regular description row (shown when not in the waitingForInput conclusion state)

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
        .onDisappear {
            conclusionExpandWork?.cancel()
            conclusionCollapseWork?.cancel()
        }
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
