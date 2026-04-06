//
//  NotchView.swift
//  VibeHub
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
    @ObservedObject private var sessionMonitor = ClaudeSessionMonitor.shared
    @StateObject private var activityCoordinator = NotchActivityCoordinator.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    #if !APP_STORE
    @ObservedObject private var licenseManager = LicenseManager.shared
    #endif
    @State private var previousPendingIds: Set<String> = []
    @State private var previousWaitingForInputIds: Set<String> = []
    @State private var waitingForInputTimestamps: [String: Date] = [:]  // sessionId -> when it entered waitingForInput
    @State private var pendingCompletionOpenWork: DispatchWorkItem? = nil
    @State private var pendingSoundWork: [String: DispatchWorkItem] = [:]  // sessionId -> pending sound work
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
            viewModel.closedContentWidth = closedContentWidth
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
        .onChange(of: closedContentWidth) { _, newWidth in
            viewModel.closedContentWidth = newWidth
        }
    }

    // MARK: - Notch Layout

    private var isProcessing: Bool {
        activityCoordinator.expandingActivity.show && activityCoordinator.expandingActivity.type == .claude
    }

    #if !APP_STORE
    private var isLicenseLocked: Bool {
        licenseManager.status == .locked
    }
    #endif

    /// Whether to show something in the closed notch.
    /// We keep a minimal indicator (crab + session count) whenever there are tracked sessions.
    private var showClosedActivity: Bool {
        #if !APP_STORE
        if isLicenseLocked { return true }
        #endif
        return sessionCount > 0 || isProcessing || hasPendingPermission || hasWaitingForInput
    }

    @ViewBuilder
    private var notchLayout: some View {
        VStack(spacing: 0) {
            // Header row - always present, contains crab and spinner that persist across states
            headerRow
                .frame(height: max(24, closedNotchSize.height))

            // Main content only when opened
            if viewModel.status == .opened {
                contentView
                    .frame(width: notchSize.width - 14) // Fixed width to prevent reflow
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

                    // On physical notch closed state, show project name next to crab (left wing)
                    if viewModel.hasPhysicalNotch && viewModel.status != .opened {
                        if let project = activeSessionProjectLabel {
                            Text(project)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(0.55))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                // Physical notch closed: no fixed width, let content size naturally to stay in left wing
                .frame(width: viewModel.status == .opened ? nil :
                        (viewModel.hasPhysicalNotch ? nil : sideWidth + (hasPendingPermission ? 18 : 0)))
                .padding(.leading, viewModel.status == .opened ? 8 :
                        (viewModel.hasPhysicalNotch ? 10 : 0))
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
                // Closed with activity
                if viewModel.hasPhysicalNotch {
                    // Physical notch: empty center to avoid camera housing
                    Spacer(minLength: 0)
                } else if let label = activeSessionLabel {
                    // Non-notch: show project name + scrolling title
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
                #if !APP_STORE
                if isLicenseLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(red: 1.0, green: 0.4, blue: 0.4).opacity(0.8))
                        .frame(width: viewModel.status == .opened ? 20 : sideWidth)
                }
                #endif
                let licenseBlocking: Bool = {
                    #if !APP_STORE
                    return isLicenseLocked
                    #else
                    return false
                    #endif
                }()
                if !licenseBlocking && (isProcessing || hasPendingPermission) {
                    ProcessingSpinner()
                        .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showClosedActivity)
                        .frame(width: viewModel.status == .opened ? 20 : sideWidth)
                } else if !licenseBlocking && hasWaitingForInput {
                    ReadyForInputIndicatorIcon(size: 14, color: TerminalColors.green)
                        .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showClosedActivity)
                        .frame(width: viewModel.status == .opened ? 20 : sideWidth)
                }

                // Session count badge — far right (hidden when locked)
                if viewModel.status != .opened && sessionCount > 0 && !licenseBlocking {
                    Text("\(sessionCount)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.45))
                        .padding(.leading, -2)
                        .padding(.trailing, viewModel.hasPhysicalNotch ? 6 : 0)
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

            // Settings button — opens standalone settings window
            Button {
                SettingsWindowController.shared.show()
                updateManager.markUpdateSeen()
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())

                    // Green dot for unseen update
                    if updateManager.hasUnseenUpdate {
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
            #if !APP_STORE
            // Single license gate: locked + not in settings → show activation view
            if isLicenseLocked && viewModel.contentType != .menu {
                LicenseActivationView(licenseManager: licenseManager)
            } else {
                normalContent
            }
            #else
            normalContent
            #endif
        }
        .frame(width: notchSize.width - 14) // Fixed width to prevent text reflow
        // Removed .id() - was causing view recreation and performance issues
    }

    @ViewBuilder
    private var normalContent: some View {
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
        case .onboarding:
            OnboardingView(viewModel: viewModel)
        #if APP_STORE
        case .welcome:
            OnboardingView(viewModel: viewModel)
        #endif
        }
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
                NotchLog.log("handlePending: opening for interactive tool, session=\(interactive.sessionId.prefix(12)) tool=\(interactive.pendingToolName ?? "?")")
                viewModel.notchOpen(reason: .interaction)
                viewModel.showChat(for: interactive)
            } else {
                NotchLog.log("handlePending: opening for approval, sessions=\(newlyPendingSessions.map { String($0.sessionId.prefix(12)) })")
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
            // Cancel any pending sound for stale sessions
            pendingSoundWork[staleId]?.cancel()
            pendingSoundWork.removeValue(forKey: staleId)
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
                let work = DispatchWorkItem { [self] in
                    // Re-fetch the latest snapshot.
                    guard let latest = sessionMonitor.instances.first(where: { $0.stableId == stableId }) else { return }
                    guard latest.phase == .waitingForInput else { return }

                    // Avoid popping empty/stale content.
                    let lastMsg = latest.conversationInfo.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !lastMsg.isEmpty else { return }

                    if let lastShown = lastCompletionShownAt[stableId], latest.lastActivity <= lastShown {
                        return
                    }

                    // Don't expand if the session's terminal is in the foreground
                    NotchLog.log("handleWaiting: debounce fired for session=\(stableId.prefix(16)) phase=\(latest.phase) msg=\(lastMsg.prefix(40))")
                    Task {
                        let isFocused = await TerminalActivator.shared.isSessionTerminalFocused(for: latest)
                        NotchLog.log("handleWaiting: isFocused=\(isFocused) for session=\(stableId.prefix(16))")
                        guard !isFocused else { return }

                        await MainActor.run { [self] in
                            // Re-verify session still exists and is waiting
                            guard let current = sessionMonitor.instances.first(where: { $0.stableId == stableId }),
                                  current.phase == .waitingForInput else {
                                NotchLog.log("handleWaiting: session gone or phase changed, skipping open")
                                return
                            }

                            NotchLog.log("handleWaiting: opening notch for session=\(stableId.prefix(16))")
                            lastCompletionShownAt[stableId] = Date()
                            viewModel.notchOpen(reason: .notification)
                            viewModel.showChat(for: current)
                        }
                    }
                }

                pendingCompletionOpenWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
            }

            // Play notification sound if the session is not actively focused
            // IMPORTANT: Delay the sound to avoid false positives when state transitions quickly
            // (e.g., when multiple tools execute in sequence)
            if let soundName = AppSettings.notificationSound.soundName {
                for session in newlyWaitingSessions {
                    let stableId = session.stableId
                    // Cancel any pending sound for this session
                    pendingSoundWork[stableId]?.cancel()

                    let soundWork = DispatchWorkItem { [self] in
                        // Re-check: is this session still in waitingForInput state?
                        guard let latest = sessionMonitor.instances.first(where: { $0.stableId == stableId }) else { return }
                        guard latest.phase == .waitingForInput else { return }

                        // Check if we should play sound (async check for tmux pane focus)
                        Task {
                            let shouldPlaySound = await shouldPlayNotificationSound(for: [latest])
                            if shouldPlaySound {
                                await MainActor.run {
                                    NSSound(named: soundName)?.play()
                                }
                            }
                        }
                    }

                    pendingSoundWork[stableId] = soundWork
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: soundWork)
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

// MARK: - Welcome View (App Store only)

#if APP_STORE
struct WelcomeView: View {
    @ObservedObject var viewModel: NotchViewModel

    @State private var isInstalling = false

    var body: some View {
        VStack(spacing: 16) {
            // App icon
            if let appIcon = NSImage(named: "AppIcon") {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
            }

            // Title
            Text(L10n.welcomeTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)

            // Description
            Text(L10n.welcomeSubtitle)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            // Install step hint
            Text(L10n.welcomeInstallStep)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 4)

            // Install button
            Button {
                guard !isInstalling else { return }
                Task { @MainActor in
                    isInstalling = true
                    let success = await performInstall()
                    isInstalling = false
                    if success {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            viewModel.contentType = .instances
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if isInstalling {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12))
                    }
                    Text(isInstalling ? L10n.welcomeInstallingButton : L10n.welcomeInstallButton)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white)
                )
            }
            .buttonStyle(.plain)
            .disabled(isInstalling)

            // Skip button
            Button {
                viewModel.notchClose()
            } label: {
                Text(L10n.welcomeSkipButton)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Install Flow

    @MainActor
    private func performInstall() async -> Bool {
        let home: URL = {
            if let pw = getpwuid(getuid()) {
                return URL(fileURLWithPath: String(cString: pw.pointee.pw_dir))
            }
            return FileManager.default.homeDirectoryForCurrentUser
        }()

        guard let homeDir = pickDirectory(
            title: "Grant Access",
            message: "Select your Home folder (\(home.path)) to grant access for installing hooks.",
            suggested: home,
            requiredPath: home.standardizedFileURL.path
        ) else {
            return false
        }

        _ = HookInstaller.rememberClaudeDir(homeDir)

        let ok = homeDir.startAccessingSecurityScopedResource()
        defer { if ok { homeDir.stopAccessingSecurityScopedResource() } }
        guard ok else {
            showMessage(title: "Hooks", message: "Permission denied for Home folder.")
            return false
        }

        let claudeDir = homeDir.appendingPathComponent(".claude", isDirectory: true)
        let ok1 = HookInstaller.installAppStore(claudeDir: claudeDir)

        var ok2 = true
        let wantsOpenCode = withNotchWindowDeemphasized {
            NSAlert.runWelcomeChoice(
                title: "OpenCode",
                message: "Also install the OpenCode plugin (uses ~/.config/opencode if present)?",
                primary: "Install",
                secondary: "Skip"
            )
        }

        if wantsOpenCode {
            let opencodeDir = homeDir
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("opencode", isDirectory: true)
            ok2 = HookInstaller.installOpenCodeAppStore(opencodeDir: opencodeDir)
        }

        if ok1 && ok2 {
            showMessage(title: "Hooks", message: "Installed.")
            return true
        } else if ok1 {
            showMessage(title: "Hooks", message: "Installed Claude hooks, but OpenCode plugin failed.")
            return true
        } else {
            showMessage(title: "Hooks", message: "Install failed.")
            return false
        }
    }

    @MainActor
    private func pickDirectory(title: String, message: String, suggested: URL, requiredPath: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = "Allow"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = suggested.deletingLastPathComponent()
        panel.nameFieldStringValue = suggested.lastPathComponent

        let resp = withNotchWindowDeemphasized { panel.runModal() }
        guard resp == .OK, let url = panel.url else { return nil }

        let chosen = url.standardizedFileURL.resolvingSymlinksInPath().path
        let required = URL(fileURLWithPath: requiredPath).standardizedFileURL.resolvingSymlinksInPath().path
        guard chosen == required else {
            showMessage(title: "Hooks", message: "Please select \(required).")
            return nil
        }
        return url
    }

    @MainActor
    private func showMessage(title: String, message: String) {
        _ = withNotchWindowDeemphasized {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = message
            a.addButton(withTitle: "OK")
            a.runModal()
        }
    }

    @MainActor
    private func withNotchWindowDeemphasized<T>(_ block: () -> T) -> T {
        let notchWindow = NSApp.windows.first(where: { $0 is NotchPanel })
        let prevLevel = notchWindow?.level
        notchWindow?.level = .normal
        NSApp.activate(ignoringOtherApps: true)
        defer {
            if let prevLevel { notchWindow?.level = prevLevel }
        }
        return block()
    }
}

private extension NSAlert {
    @MainActor
    static func runWelcomeChoice(title: String, message: String, primary: String, secondary: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: primary)
        a.addButton(withTitle: secondary)
        return a.runModal() == .alertFirstButtonReturn
    }
}
#endif
