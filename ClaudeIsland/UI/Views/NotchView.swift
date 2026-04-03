//
//  NotchView.swift
//  ClaudeIsland
//
//  The main dynamic island SwiftUI view with accurate notch shape
//

import AppKit
import CoreGraphics
import SwiftUI

// Corner radius constants
private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

// Visual tuning: closed notch should track the hardware more closely.
// The old value (closed.bottom) made the pill look noticeably wider than the camera housing
// on some setups (e.g. screen sharing / different menu bar layouts).
private let closedHorizontalPadding: CGFloat = cornerRadiusInsets.closed.top

struct NotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var sessionMonitor = ClaudeSessionMonitor()
    @StateObject private var activityCoordinator = NotchActivityCoordinator.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var previousPendingIds: Set<String> = []
    @State private var previousWaitingForInputIds: Set<String> = []
    @State private var waitingForInputTimestamps: [String: Date] = [:]  // sessionId -> when it entered waitingForInput
    @State private var pendingCompletionOpenWork: DispatchWorkItem? = nil
    @State private var lastCompletionShownAt: [String: Date] = [:]
    @State private var isVisible: Bool = false
    @State private var isHovering: Bool = false
    @State private var isBouncing: Bool = false

    @Namespace private var activityNamespace

    /// Whether any Claude session is currently processing or compacting
    private var isAnyProcessing: Bool {
        sessionMonitor.instances.contains { $0.phase == .processing || $0.phase == .compacting }
    }

    /// Whether any Claude session has a pending permission request
    private var hasPendingPermission: Bool {
        sessionMonitor.instances.contains { $0.phase.isWaitingForApproval }
    }

    /// Whether any Claude session is waiting for user input (done/ready state) within the display window
    private var hasWaitingForInput: Bool {
        let now = Date()
        let displayDuration: TimeInterval = 30  // Show checkmark for 30 seconds

        return sessionMonitor.instances.contains { session in
            guard session.phase == .waitingForInput else { return false }
            // Only show if within the 30-second display window
            if let enteredAt = waitingForInputTimestamps[session.stableId] {
                return now.timeIntervalSince(enteredAt) < displayDuration
            }
            return false
        }
    }

    /// Label for the closed pill center.
    /// Only shown while at least one session is actively running.
    private var activeSessionLabel: String? {
        guard showClosedActivity else { return nil }

        // If nothing is running, keep the closed pill minimal: icon + count badge only.
        guard isAnyProcessing else { return nil }

        return closedPillActiveSession?.compactDisplayTitle
    }

    private var activeSessionProjectLabel: String? {
        guard showClosedActivity else { return nil }
        guard isAnyProcessing else { return nil }
        return closedPillActiveSession?.projectName
    }

    private var closedPillActiveSession: SessionState? {
        sessionMonitor.instances
            .filter { $0.phase == .processing || $0.phase == .compacting }
            .sorted(by: { $0.lastActivity > $1.lastActivity })
            .first
    }

    private var activeSessionMarqueeTrigger: String? {
        guard let active = closedPillActiveSession else { return nil }
        return "\(active.stableId)-\(active.phase.uiKey)"
    }

    /// Total number of tracked sessions
    private var sessionCount: Int {
        sessionMonitor.instances.count
    }

    // MARK: - Sizing

    private var closedNotchSize: CGSize {
        CGSize(
            width: viewModel.deviceNotchRect.width,
            height: viewModel.deviceNotchRect.height
        )
    }

    private let countBadgeWidth: CGFloat = 16

    /// Extra width for expanding activities (like Dynamic Island)
    private var expansionWidth: CGFloat {
        let permissionIndicatorWidth: CGFloat = hasPendingPermission ? 18 : 0
        let sessionBadgeWidth: CGFloat = (showClosedActivity && sessionCount > 0) ? countBadgeWidth : 0

        // When we show a title (running only), give it extra breathing room.
        let titleExtra: CGFloat = {
            guard viewModel.status != .opened, isAnyProcessing, let label = activeSessionLabel else { return 0 }
            return min(140, max(70, CGFloat(label.count) * 4))
        }()

        // If we're only showing the idle indicator (crab + count badge), keep the default notch width.
        if !isAnyProcessing && !hasPendingPermission && !hasWaitingForInput {
            return 0
        }

        let baseWidth = 2 * max(0, closedNotchSize.height - 12) + 20
        return baseWidth + permissionIndicatorWidth + sessionBadgeWidth + titleExtra
    }

    private var notchSize: CGSize {
        switch viewModel.status {
        case .closed, .popping:
            return closedNotchSize
        case .opened:
            return viewModel.openedSize
        }
    }

    /// Width of the closed content (notch + any expansion)
    private var closedContentWidth: CGFloat {
        closedNotchSize.width + expansionWidth
    }


    // MARK: - Corner Radii

    private var topCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.bottom
            : cornerRadiusInsets.closed.bottom
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }

    // Animation springs
    private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            // Outer container does NOT receive hits - only the notch content does
            VStack(spacing: 0) {
                notchLayout
                    .frame(
                        width: viewModel.status == .opened ? notchSize.width : closedContentWidth,
                        alignment: .top
                    )
                    .padding(
                        .horizontal,
                        viewModel.status == .opened
                            ? cornerRadiusInsets.opened.top
                            : closedHorizontalPadding
                    )
                    .padding([.horizontal, .bottom], viewModel.status == .opened ? 12 : 0)
                    .background(.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: (viewModel.status == .opened || isHovering) ? .black.opacity(0.7) : .clear,
                        radius: 6
                    )
                    .frame(
                        width: viewModel.status == .opened ? notchSize.width : closedContentWidth,
                        height: viewModel.status == .opened ? notchSize.height : nil,
                        alignment: .top
                    )
                    .animation(viewModel.status == .opened ? openAnimation : closeAnimation, value: viewModel.status)
                    .animation(openAnimation, value: notchSize) // Animate container size changes between content types
                    .animation(.smooth, value: activityCoordinator.expandingActivity)
                    .animation(.smooth, value: hasPendingPermission)
                    .animation(.smooth, value: hasWaitingForInput)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isBouncing)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                            isHovering = hovering
                        }
                    }
                    .onTapGesture {
                        if viewModel.status != .opened {
                            viewModel.notchOpen(reason: .click)
                        }
                    }
            }
        }
        .opacity(isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onAppear {
            sessionMonitor.startMonitoring()
            // On non-notched devices, keep visible so users have a target to interact with
            if !viewModel.hasPhysicalNotch {
                isVisible = true
            }
        }
        .onChange(of: viewModel.status) { oldStatus, newStatus in
            handleStatusChange(from: oldStatus, to: newStatus)
        }
        .onChange(of: sessionMonitor.pendingInstances) { _, sessions in
            handlePendingSessionsChange(sessions)
        }
        .onChange(of: sessionMonitor.instances) { _, instances in
            handleProcessingChange()
            handleWaitingForInputChange(instances)
        }
    }

    // MARK: - Notch Layout

    private var isProcessing: Bool {
        activityCoordinator.expandingActivity.show && activityCoordinator.expandingActivity.type == .claude
    }

    /// Whether to show something in the closed notch.
    /// We keep a minimal indicator (crab + session count) whenever there are tracked sessions.
    private var showClosedActivity: Bool {
        sessionCount > 0 || isProcessing || hasPendingPermission || hasWaitingForInput
    }

    @ViewBuilder
    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row - always present, contains crab and spinner that persist across states
            headerRow
                .frame(height: max(24, closedNotchSize.height))

            // Main content only when opened
            if viewModel.status == .opened {
                contentView
                    .frame(width: notchSize.width - 24) // Fixed width to prevent reflow
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.smooth(duration: 0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        )
                    )
            }
        }
    }

    // MARK: - Header Row (persists across states)

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 0) {
            // Left side - crab + optional permission indicator (visible when processing, pending, or waiting for input)
            if showClosedActivity {
                HStack(spacing: 4) {
                    ClaudeCrabIcon(size: 14, animateLegs: isProcessing)
                        .matchedGeometryEffect(id: "crab", in: activityNamespace, isSource: showClosedActivity)

                    // Permission indicator only (amber) - waiting for input shows checkmark on right
                    if hasPendingPermission {
                        PermissionIndicatorIcon(size: 14, color: Color(red: 0.85, green: 0.47, blue: 0.34))
                            .matchedGeometryEffect(id: "status-indicator", in: activityNamespace, isSource: showClosedActivity)
                    }
                }
                .frame(width: viewModel.status == .opened ? nil : sideWidth + (hasPendingPermission ? 18 : 0))
                .padding(.leading, viewModel.status == .opened ? 8 : 0)
            }

            // Center content
            if viewModel.status == .opened {
                // Opened: show header content
                openedHeaderContent
            } else if !showClosedActivity {
                // Closed without activity: empty space
                Rectangle()
                    .fill(.clear)
                    .frame(width: closedNotchSize.width - 20)
            } else {
                // Closed with activity: project label or black spacer (with optional bounce)
                if let label = activeSessionLabel {
                    let leftWidth = sideWidth + (hasPendingPermission ? 18 : 0)
                    let rightWidth = sideWidth
                    let badgeWidth = (viewModel.status != .opened && sessionCount > 0) ? countBadgeWidth : 0
                    let labelWidth = max(0, closedContentWidth - leftWidth - rightWidth - badgeWidth)

                    HStack(spacing: 6) {
                        if let project = activeSessionProjectLabel {
                            Text(project)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(0.45))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(width: min(84, labelWidth * 0.38), alignment: .leading)
                        }

                        if let project = activeSessionProjectLabel, label != project {
                            Text("·")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(0.35))
                        }

                        MarqueeText(
                            text: label,
                            fontSize: 10,
                            fontWeight: .medium,
                            nsFontWeight: .medium,
                            color: .white.opacity(0.6),
                            trigger: activeSessionMarqueeTrigger ?? label
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: labelWidth, height: closedNotchSize.height, alignment: .leading)
                    .offset(x: isBouncing ? 8 : 0)
                } else {
                    Rectangle()
                        .fill(.black)
                        .frame(maxWidth: .infinity)
                }
            }

            // Right side - spinner when processing/pending, checkmark when waiting for input
            if showClosedActivity {
                if isProcessing || hasPendingPermission {
                    ProcessingSpinner()
                        .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showClosedActivity)
                        .frame(width: viewModel.status == .opened ? 20 : sideWidth)
                } else if hasWaitingForInput {
                    ReadyForInputIndicatorIcon(size: 14, color: TerminalColors.green)
                        .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showClosedActivity)
                        .frame(width: viewModel.status == .opened ? 20 : sideWidth)
                }

                // Session count badge — far right
                if viewModel.status != .opened && sessionCount > 0 {
                    Text("\(sessionCount)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.45))
                        .frame(width: countBadgeWidth, alignment: .center)
                }
            }
        }
        .frame(height: closedNotchSize.height)
    }

    private var sideWidth: CGFloat {
        max(0, closedNotchSize.height - 12) + 10
    }

    // MARK: - Opened Header Content

    @ViewBuilder
    private var openedHeaderContent: some View {
        HStack(spacing: 12) {
            // Show static crab only if not showing activity in headerRow
            // (headerRow handles crab + indicator when showClosedActivity is true)
            if !showClosedActivity {
                ClaudeCrabIcon(size: 14)
                    .matchedGeometryEffect(id: "crab", in: activityNamespace, isSource: !showClosedActivity)
                    .padding(.leading, 8)
            }

            Spacer()

            // Menu toggle
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    viewModel.toggleMenu()
                    if viewModel.contentType == .menu {
                        updateManager.markUpdateSeen()
                    }
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: viewModel.contentType == .menu ? "xmark" : "line.3.horizontal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())

                    // Green dot for unseen update
                    if updateManager.hasUnseenUpdate && viewModel.contentType != .menu {
                        Circle()
                            .fill(TerminalColors.green)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: 2)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Content View (Opened State)

    @ViewBuilder
    private var contentView: some View {
        Group {
            switch viewModel.contentType {
            case .instances:
                ClaudeInstancesView(
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
            case .menu:
                NotchMenuView(viewModel: viewModel)
            case .remote:
                RemoteHostsView(viewModel: viewModel)
            case .chat(let session):
                ChatView(
                    sessionId: session.sessionId,
                    initialSession: session,
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
            }
        }
        .frame(width: notchSize.width - 24) // Fixed width to prevent text reflow
        // Removed .id() - was causing view recreation and performance issues
    }

    // MARK: - Event Handlers

    private func handleProcessingChange() {
        if isAnyProcessing || hasPendingPermission {
            // Show claude activity when processing or waiting for permission
            activityCoordinator.showActivity(type: .claude)
            isVisible = true
        } else if hasWaitingForInput {
            // Keep visible for waiting-for-input but hide the processing spinner
            activityCoordinator.hideActivity()
            isVisible = true
        } else {
            // Hide activity when done
            activityCoordinator.hideActivity()

            // Delay hiding the notch until animation completes
            // Don't hide on non-notched devices - users need a visible target
            if viewModel.status == .closed && viewModel.hasPhysicalNotch {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if !isAnyProcessing && !hasPendingPermission && !hasWaitingForInput && viewModel.status == .closed {
                        isVisible = false
                    }
                }
            }
        }
    }

    private func handleStatusChange(from oldStatus: NotchStatus, to newStatus: NotchStatus) {
        switch newStatus {
        case .opened, .popping:
            isVisible = true
            // Clear waiting-for-input timestamps only when manually opened (user acknowledged)
            if viewModel.openReason == .click || viewModel.openReason == .hover {
                waitingForInputTimestamps.removeAll()
            }
        case .closed:
            // Don't hide on non-notched devices - users need a visible target
            guard viewModel.hasPhysicalNotch else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if viewModel.status == .closed && !isAnyProcessing && !hasPendingPermission && !hasWaitingForInput && !activityCoordinator.expandingActivity.show {
                    isVisible = false
                }
            }
        }
    }

    private func handlePendingSessionsChange(_ sessions: [SessionState]) {
        let currentIds = Set(sessions.map { $0.stableId })
        let newPendingIds = currentIds.subtracting(previousPendingIds)

        // If a session transitions into an approval state, proactively open the notch so the UI is immediately available.
        // (Completion is handled separately by handleWaitingForInputChange to avoid stealing focus.)
        if !newPendingIds.isEmpty,
           (viewModel.status == .closed || viewModel.status == .popping) {
            let newlyPendingSessions = sessions
                .filter { newPendingIds.contains($0.stableId) }
                .filter { $0.phase.isWaitingForApproval }

            guard !newlyPendingSessions.isEmpty else {
                previousPendingIds = currentIds
                return
            }

            // Prefer jumping directly into chat for interactive tools (eg OpenCode AskUserQuestion),
            // since the instances list only shows a "Needs your input" hint.
            if let interactive = newlyPendingSessions.first(where: { $0.pendingToolName == "AskUserQuestion" }) {
                viewModel.notchOpen(reason: .interaction)
                viewModel.showChat(for: interactive)
            } else {
                viewModel.notchOpen(reason: .interaction)
            }
        }

        previousPendingIds = currentIds
    }

    private func handleWaitingForInputChange(_ instances: [SessionState]) {
        // Get sessions that are now waiting for input
        let waitingForInputSessions = instances.filter { $0.phase == .waitingForInput }
        let currentIds = Set(waitingForInputSessions.map { $0.stableId })
        let newWaitingIds = currentIds.subtracting(previousWaitingForInputIds)

        // Track timestamps for newly waiting sessions
        let now = Date()
        for session in waitingForInputSessions where newWaitingIds.contains(session.stableId) {
            waitingForInputTimestamps[session.stableId] = now
        }

        // Clean up timestamps for sessions no longer waiting
        let staleIds = Set(waitingForInputTimestamps.keys).subtracting(currentIds)
        for staleId in staleIds {
            waitingForInputTimestamps.removeValue(forKey: staleId)
        }

        // Bounce the notch when a session newly enters waitingForInput state
        if !newWaitingIds.isEmpty {
            // Get the sessions that just entered waitingForInput
            let newlyWaitingSessions = waitingForInputSessions.filter { newWaitingIds.contains($0.stableId) }

            // When work completes, proactively open the notch so the user can see the outcome.
            // Use the notification reason so we don't steal focus.
            if AppSettings.expandOnCompletion,
               (viewModel.status == .closed || viewModel.status == .popping),
               let focusSession = newlyWaitingSessions.sorted(by: { $0.lastActivity > $1.lastActivity }).first {
                // Debounce: wait a moment so message history/title has time to sync.
                // Cancel if the session goes back to processing.
                pendingCompletionOpenWork?.cancel()

                let stableId = focusSession.stableId
                let work = DispatchWorkItem {
                    // Re-fetch the latest snapshot.
                    guard let latest = sessionMonitor.instances.first(where: { $0.stableId == stableId }) else { return }
                    guard latest.phase == .waitingForInput else { return }

                    // Avoid popping empty/stale content.
                    let lastMsg = latest.conversationInfo.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !lastMsg.isEmpty else { return }

                    if let lastShown = lastCompletionShownAt[stableId], latest.lastActivity <= lastShown {
                        return
                    }
                    lastCompletionShownAt[stableId] = Date()

                    viewModel.notchOpen(reason: .notification)
                    viewModel.showChat(for: latest)
                }

                pendingCompletionOpenWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
            }

            // Play notification sound if the session is not actively focused
            if let soundName = AppSettings.notificationSound.soundName {
                // Check if we should play sound (async check for tmux pane focus)
                Task {
                    let shouldPlaySound = await shouldPlayNotificationSound(for: newlyWaitingSessions)
                    if shouldPlaySound {
                        await MainActor.run {
                            NSSound(named: soundName)?.play()
                        }
                    }
                }
            }

            // Trigger bounce animation to get user's attention
            DispatchQueue.main.async {
                isBouncing = true
                // Bounce back after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isBouncing = false
                }
            }

            // Schedule hiding the checkmark after 30 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [self] in
                // Trigger a UI update to re-evaluate hasWaitingForInput
                handleProcessingChange()
            }
        }

        previousWaitingForInputIds = currentIds
    }

    /// Determine if notification sound should play for the given sessions
    /// Returns true if ANY session is not actively focused
    private func shouldPlayNotificationSound(for sessions: [SessionState]) async -> Bool {
        for session in sessions {
            guard let pid = session.pid else {
                // No PID means we can't check focus, assume not focused
                return true
            }

            let isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
            if !isFocused {
                return true
            }
        }

        return false
    }
}
