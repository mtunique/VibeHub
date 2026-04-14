//
//  ChatView.swift
//  VibeHub
//
//  Redesigned chat interface with clean visual hierarchy
//

import AppKit
import Combine
import SwiftUI

// MARK: - Display Context Environment

struct IsNotchModeKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

extension EnvironmentValues {
    var isNotchMode: Bool {
        get { self[IsNotchModeKey.self] }
        set { self[IsNotchModeKey.self] = newValue }
    }
}

struct ChatView: View {
    let sessionId: String
    let initialSession: SessionState
    let sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel

    @State private var inputText: String = ""
    @State private var history: [ChatHistoryItem] = []
    /// Optimistic local echoes of user messages that have been sent via
    /// `sendToSession` but haven't yet round-tripped back through the hook
    /// + JSONL/SQLite sync. Merged into the displayed history so the user
    /// sees their prompt immediately instead of waiting ~0.5-1s for the
    /// real row to arrive.
    @State private var pendingUserEchos: [ChatHistoryItem] = []
    @State private var session: SessionState
    @State private var isLoading: Bool = true
    @State private var hasLoadedOnce: Bool = false
    @State private var shouldScrollToBottom: Bool = false
    @State private var isAutoscrollPaused: Bool = false
    @State private var newMessageCount: Int = 0
    @State private var previousHistoryCount: Int = 0
    @State private var isBottomVisible: Bool = true
    @State private var inputHintText: String? = nil
    @FocusState private var isInputFocused: Bool

    init(sessionId: String, initialSession: SessionState, sessionMonitor: ClaudeSessionMonitor, viewModel: NotchViewModel) {
        self.sessionId = sessionId
        self.initialSession = initialSession
        self.sessionMonitor = sessionMonitor
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._session = State(initialValue: initialSession)

        // Initialize from cache if available (prevents loading flicker on view recreation)
        let cachedHistory = ChatHistoryManager.shared.history(for: sessionId)
        let alreadyLoaded = !cachedHistory.isEmpty
        self._history = State(initialValue: cachedHistory)
        self._isLoading = State(initialValue: !alreadyLoaded)
        self._hasLoadedOnce = State(initialValue: alreadyLoaded)
    }

    /// Whether we're waiting for approval
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    /// Extract the tool name if waiting for approval
    private var approvalTool: String? {
        session.phase.approvalToolName
    }

    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header
                chatHeader

                // Messages
                if isLoading {
                    loadingState
                } else if history.isEmpty {
                    emptyState
                } else {
                    messageList
                }

                // Approval bar, interactive prompt, or Input bar
                if let tool = approvalTool {
                    if tool == "AskUserQuestion" {
                        Group {
                            if let payload = AskUserQuestionPayload.from(toolInput: session.activePermission?.toolInput) {
                                AskUserQuestionBar(
                                    payload: payload,
                                    onSubmit: { answers in
                                        sessionMonitor.submitAskUserQuestion(sessionId: sessionId, answers: answers)
                                    },
                                    onUseTerminal: isOpenCodeSession ? {
                                        sessionMonitor.deferAskUserQuestionToTerminal(sessionId: sessionId)
                                    } : nil
                                )
                            } else {
                                // Fallback: free text input for unstructured questions
                                claudeCodeQuestionBar
                            }
                        }
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity
                        ))
                    } else {
                        approvalBar(tool: tool)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity
                            ))
                    }
                } else if canSendMessages {
                    inputBar
                        .transition(.opacity)
                } else {
                    revealInTerminalBar
                        .transition(.opacity)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isWaitingForApproval)
        .animation(nil, value: viewModel.status)
        .task {
            // Skip if already loaded (prevents redundant work on view recreation)
            guard !hasLoadedOnce else { return }
            hasLoadedOnce = true

            // Check if already loaded (from previous visit)
            if ChatHistoryManager.shared.isLoaded(sessionId: sessionId) {
                history = ChatHistoryManager.shared.history(for: sessionId)
                isLoading = false
                return
            }

            // Load in background, show loading state
            await ChatHistoryManager.shared.loadFromFile(sessionId: sessionId, cwd: session.cwd)
            history = ChatHistoryManager.shared.history(for: sessionId)

            withAnimation(.easeOut(duration: 0.2)) {
                isLoading = false
            }
        }
        .onReceive(ChatHistoryManager.shared.$histories) { histories in
            // Update when count changes, last item differs, or content changes (e.g., tool status)
            if let newHistory = histories[sessionId] {
                let countChanged = newHistory.count != history.count
                let lastItemChanged = newHistory.last?.id != history.last?.id
                // Always update - the @Published ensures we only get notified on real changes
                // This allows tool status updates (waitingForApproval -> running) to reflect
                if countChanged || lastItemChanged || newHistory != history {
                    // Track new messages when autoscroll is paused
                    if isAutoscrollPaused && newHistory.count > previousHistoryCount {
                        let addedCount = newHistory.count - previousHistoryCount
                        newMessageCount += addedCount
                        previousHistoryCount = newHistory.count
                    }

                    history = newHistory
                    pruneMatchedEchos()

                    // Auto-scroll to bottom only if autoscroll is NOT paused
                    if !isAutoscrollPaused && countChanged {
                        shouldScrollToBottom = true
                    }

                    // If we have data, skip loading state (handles view recreation)
                    if isLoading && !newHistory.isEmpty {
                        isLoading = false
                    }
                }
            } else if hasLoadedOnce {
                // Session was loaded but is now gone (removed via /clear) - navigate back
                viewModel.exitChat()
            }
        }
        .onReceive(sessionMonitor.$instances) { sessions in
            if let updated = sessions.first(where: { $0.sessionId == sessionId }),
               updated != session {
                // Check if permission was just accepted (transition from waitingForApproval to processing)
                let wasWaiting = isWaitingForApproval
                session = updated
                let isNowProcessing = updated.phase == .processing

                if wasWaiting && isNowProcessing {
                    // Scroll to bottom after permission accepted (with slight delay)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        shouldScrollToBottom = true
                    }
                }
            }
        }
        .onChange(of: canSendMessages) { _, canSend in
            // Auto-focus input when tmux messaging becomes available
            if canSend && !isInputFocused {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isInputFocused = true
                }
            }
        }
        .onChange(of: isInputFocused) { _, focused in
            // Focus gained → enter keyboard mode (activate VibeHub so text
            // typing reaches the field). Focus lost → exit keyboard mode
            // immediately so VibeHub releases frontmost and click-through
            // to other apps resumes.
            if focused {
                viewModel.enterKeyboardMode()
            } else {
                viewModel.exitKeyboardMode()
            }
        }
        .onAppear {
            // Auto-focus input when chat opens and tmux messaging is available
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if canSendMessages {
                    isInputFocused = true
                }
            }
        }
        .onDisappear {
            viewModel.exitKeyboardMode()
        }
    }

    // MARK: - Header

    @State private var isHeaderHovered = false

    private var chatHeader: some View {
        Button {
            viewModel.exitChat()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary.opacity(isHeaderHovered ? 1.0 : 0.6))
                    .frame(width: 24, height: 24)

                Text(session.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary.opacity(isHeaderHovered ? 1.0 : 0.85))
                    .lineLimit(1)

                // Tags
                HStack(spacing: 4) {
                    // Software tag (pulled from SupportedCLI so forks inherit).
                    let cliSourceColor = session.source.themeColor
                    Text(session.source.displayName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(cliSourceColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(cliSourceColor.opacity(0.15))
                        .clipShape(Capsule())

                    // Remote host tag
                    if let hostName = remoteHostName {
                        Text(hostName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(TerminalColors.cyan)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(TerminalColors.cyan.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHeaderHovered ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHeaderHovered = $0 }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isNotchMode ? Color.black.opacity(0.2) : Color.white.opacity(0.05))
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [fadeColor.opacity(fadeOpacity), fadeColor.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: 24) // Push below header
            .allowsHitTesting(false)
        }
        .zIndex(1) // Render above message list
    }

    /// Whether the session is currently processing
    private var isProcessing: Bool {
        session.phase == .processing || session.phase == .compacting
    }

    /// History actually shown in the chat list — `history` from the store
    /// plus any optimistic user echoes that haven't been matched yet.
    /// Sorted by timestamp so an echo slots in at the bottom of the list.
    private var displayedHistory: [ChatHistoryItem] {
        guard !pendingUserEchos.isEmpty else { return history }
        return (history + pendingUserEchos).sorted { $0.timestamp < $1.timestamp }
    }

    /// Remove any optimistic echoes that have now been matched by a real
    /// user message in `history`. Matching is by trimmed text contents and
    /// timestamp window so text arriving slightly after the echo still
    /// counts as the same submission.
    private func pruneMatchedEchos() {
        guard !pendingUserEchos.isEmpty else { return }
        let now = Date()
        // Drop echoes older than 30s even if unmatched — avoids unbounded
        // accumulation if a send never round-trips back (session ended,
        // network error, user navigated away before sync landed).
        pendingUserEchos = pendingUserEchos.filter { echo in
            guard now.timeIntervalSince(echo.timestamp) < 30 else { return false }
            guard case .user(let echoText) = echo.type else { return false }
            let echoTrimmed = echoText.trimmingCharacters(in: .whitespacesAndNewlines)
            let cutoff = echo.timestamp.addingTimeInterval(-5)
            let matched = history.contains { item in
                guard item.timestamp >= cutoff else { return false }
                if case .user(let text) = item.type {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines) == echoTrimmed
                }
                return false
            }
            return !matched
        }
    }

    /// Get the last user message ID for stable text selection per turn
    private var lastUserMessageId: String {
        for item in displayedHistory.reversed() {
            if case .user = item.type {
                return item.id
            }
        }
        return ""
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.4)))
                .scaleEffect(0.8)
            Text(L10n.loadingMessages)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 24))
                .foregroundColor(.primary.opacity(0.2))
            Text(L10n.noMessagesYet)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Message List

    /// Background color for fade gradients
    @Environment(\.isNotchMode) private var isNotchMode
    private var fadeColor: Color { Color.black }
    private var fadeOpacity: Double { isNotchMode ? 0.7 : 0.0 }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 16) {
                    // Invisible anchor at bottom (first due to flip)
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")

                    // Processing indicator at bottom (first due to flip)
                    if isProcessing {
                        ProcessingIndicatorView(turnId: lastUserMessageId)
                            .padding(.horizontal, 16)
                            .scaleEffect(x: 1, y: -1)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.95)).combined(with: .offset(y: -4)),
                                removal: .opacity
                            ))
                    }

                    ForEach(groupChatItems(displayedHistory).reversed()) { displayItem in
                        ChatDisplayItemView(displayItem: displayItem, sessionId: sessionId)
                            .padding(.horizontal, 16)
                            .scaleEffect(x: 1, y: -1)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.98)),
                                removal: .opacity
                            ))
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 20)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isProcessing)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: history.count)
            }
            .scaleEffect(x: 1, y: -1)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Check if we're near the top of the content (which is bottom in inverted view)
                // contentOffset.y near 0 means at bottom, larger means scrolled up
                geometry.contentOffset.y < 50
            } action: { wasAtBottom, isNowAtBottom in
                if wasAtBottom && !isNowAtBottom {
                    // User scrolled away from bottom
                    pauseAutoscroll()
                } else if !wasAtBottom && isNowAtBottom && isAutoscrollPaused {
                    // User scrolled back to bottom
                    resumeAutoscroll()
                }
            }
            .onChange(of: shouldScrollToBottom) { _, shouldScroll in
                if shouldScroll {
                    withAnimation(.easeOut(duration: 0.3)) {
                        // In inverted scroll, use .bottom anchor to scroll to the visual bottom
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    shouldScrollToBottom = false
                    resumeAutoscroll()
                }
            }
            // New messages indicator overlay
            .overlay(alignment: .bottom) {
                if isAutoscrollPaused && newMessageCount > 0 {
                    NewMessagesIndicator(count: newMessageCount) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            // In inverted scroll, use .bottom anchor to scroll to the visual bottom
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        resumeAutoscroll()
                    }
                    .padding(.bottom, 16)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity
                    ))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isAutoscrollPaused && newMessageCount > 0)
        }
    }

    // MARK: - Input Bar

    private var isOpenCodeSession: Bool {
        session.source == .opencode
    }

    private var isCodexSession: Bool {
        session.source == .codex
    }

    /// Display name of the remote host, if this is a remote session
    private var remoteHostName: String? {
        guard let hostId = session.remoteHostId else { return nil }
        return RemoteManager.shared.hosts.first(where: { $0.id == hostId })?.name
            ?? hostId.prefix(8).description
    }

    /// Can send messages if we can reach the session.
    /// - cmux: always (we have a workspace/surface id to target via `cmux send`).
    /// - OpenCode: always (control socket / HTTP / clipboard fallback).
    /// - tmux: send-keys via pid-based pane lookup, no tty needed.
    /// - AppleScript: Terminal.app and iTerm2 expose scriptable text input.
    /// - TIOCSTI: last resort, probed by the hook on every invocation.
    private var canSendMessages: Bool {
        if session.isInCmux { return true }
        if isOpenCodeSession { return true }
        if session.isInTmux { return true }
        guard session.tty != nil else { return false }
        if !session.isRemote && TerminalTextSender.canSend(session: session) { return true }
        return session.canInjectKeystrokes
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField(
                canSendMessages
                    ? (isOpenCodeSession ? L10n.messageOpenCode : L10n.messageClaude)
                    : L10n.noTTYAvailable,
                text: $inputText
            )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(canSendMessages ? .primary : .primary.opacity(0.4))
                .focused($isInputFocused)
                .simultaneousGesture(TapGesture().onEnded {
                    // Explicit tap on the field: enter keyboard mode first
                    // so VibeHub activates before the SwiftUI focus fires,
                    // then nudge the focus state a beat later once the
                    // window has become key.
                    viewModel.enterKeyboardMode()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isInputFocused = true
                    }
                })
                .disabled(!canSendMessages)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(canSendMessages ? 0.08 : 0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                        )
                )
                .onSubmit {
                    sendMessage()
                }

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor({
                        if !canSendMessages || inputText.isEmpty {
                            return isNotchMode ? Color.white.opacity(0.2) : Color.primary.opacity(0.2)
                        }
                        return isNotchMode ? Color.white.opacity(0.9) : Color.accentColor
                    }())
            }
            .buttonStyle(.plain)
            .disabled(!canSendMessages || inputText.isEmpty)
        }
        .overlay(alignment: .topLeading) {
            if let inputHintText {
                Text(inputHintText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isNotchMode ? .black.opacity(0.85) : .white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isNotchMode ? Color.white.opacity(0.9) : Color.accentColor)
                    .clipShape(Capsule())
                    .offset(x: 18, y: -10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isNotchMode ? Color.black.opacity(0.2) : Color.white.opacity(0.05))
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [fadeColor.opacity(0), fadeColor.opacity(fadeOpacity)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: -24) // Push above input bar
            .allowsHitTesting(false)
        }
        .zIndex(1) // Render above message list
    }

    // MARK: - Reveal in Terminal Bar

    private var revealInTerminalBar: some View {
        HStack {
            Spacer()
            Button {
                focusTerminal()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "eye")
                        .font(.system(size: 12, weight: .medium))
                    Text(L10n.revealSession)
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(isNotchMode ? .black : .white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(isNotchMode ? Color.white.opacity(0.9) : Color.accentColor)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isNotchMode ? Color.black.opacity(0.2) : Color.white.opacity(0.05))
    }

    // MARK: - Approval Bar

    private func approvalBar(tool: String) -> some View {
        ChatApprovalBar(
            tool: tool,
            toolInput: session.pendingToolInput,
            allowAlways: isOpenCodeSession,
            onApprove: { approvePermission() },
            onAlways: { approvePermissionAlways() },
            onDeny: { denyPermission() }
        )
    }

    // MARK: - Claude Code Question Bar

    /// Extract question and options from AskUserQuestion tool input
    private var askUserQuestionData: (question: String?, options: [String]) {
        guard let input = session.activePermission?.toolInput else { return (nil, []) }
        let question: String? =
            (input["question"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (input["text"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 }
        let options: [String] = (input["options"]?.value as? [Any])?.compactMap { $0 as? String } ?? []
        return (question, options)
    }

    /// Bar for Claude Code AskUserQuestion — shows question + options or text input
    private var claudeCodeQuestionBar: some View {
        let data = askUserQuestionData
        return ClaudeCodeQuestionBar(
            question: data.question,
            options: data.options,
            onSubmit: { answer in
                // 1. Allow the permission so Claude Code proceeds
                approvePermission()
                // 2. Wait for Claude Code to process the approval before sending answer
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    await sendToSession(answer)
                }
            },
            onGoToTerminal: {
                approvePermission()
                focusTerminal()
            }
        )
    }

    // MARK: - Autoscroll Management

    /// Pause autoscroll (user scrolled away from bottom)
    private func pauseAutoscroll() {
        isAutoscrollPaused = true
        previousHistoryCount = history.count
    }

    /// Resume autoscroll and reset new message count
    private func resumeAutoscroll() {
        isAutoscrollPaused = false
        newMessageCount = 0
        previousHistoryCount = history.count
    }

    // MARK: - Actions

    private func focusTerminal() {
        Task {
            await TerminalActivator.shared.activateTerminal(for: session)
        }
    }

    private func approvePermission() {
        sessionMonitor.approvePermission(sessionId: sessionId)
    }

    private func approvePermissionAlways() {
        sessionMonitor.approvePermissionAlways(sessionId: sessionId)
    }

    private func denyPermission() {
        sessionMonitor.denyPermission(sessionId: sessionId, reason: nil)
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""

        // Resume autoscroll when user sends a message
        resumeAutoscroll()
        shouldScrollToBottom = true

        // Immediately echo the user's prompt into the chat view so there's
        // no visible lag between clicking send and seeing the message. The
        // real row will arrive shortly via UserPromptSubmit → JSONL sync
        // (Claude/forks) or applyOpenCodeChatItems (OpenCode); when it does,
        // `pruneMatchedEchos` removes the optimistic copy.
        let echo = ChatHistoryItem(
            id: "optimistic-user-\(UUID().uuidString)",
            type: .user(text),
            timestamp: Date()
        )
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            pendingUserEchos.append(echo)
        }

        Task {
            await sendToSession(text)
        }
    }

    private func sendToSession(_ text: String) async {
        if session.isRemote {
            if isOpenCodeSession {
                let res = await RemoteActions.sendOpenCodePrompt(session: session, text: text)
                if !res.ok {
                    await MainActor.run {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            inputHintText = L10n.remoteSendFailed + (res.hint.map { " (\($0))" } ?? "")
                        }
                    }
                }
            } else {
                let res = await RemoteActions.sendClaudeMessage(session: session, text: text)
                if !res.ok {
                    await MainActor.run {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            inputHintText = L10n.remoteSendFailed + (res.hint.map { " (\($0))" } ?? "")
                        }
                    }
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(.easeOut(duration: 0.2)) {
                    inputHintText = nil
                }
            }
            return
        }

        if isOpenCodeSession {
            let result = await sendToOpenCode(text)
            if !result.success {
                await MainActor.run {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)

                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        if let hint = result.hint {
                            inputHintText = L10n.copied(hint: hint)
                        } else {
                            inputHintText = L10n.copiedPasteInTerminal
                        }
                    }
                }

                focusTerminal()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(.easeOut(duration: 0.2)) {
                    inputHintText = nil
                }
            }
            return
        }

        // cmux multiplexer: use the cmux CLI to write directly into the
        // target surface. The CLI reads CMUX_WORKSPACE_ID / CMUX_SURFACE_ID
        // from the hook's environment, and VibeHub forwards them via the
        // socket payload — so we can target the exact cmux surface running
        // this Claude session without fighting TIOCSTI or AppleScript.
        if session.isInCmux {
            let ok = await CmuxSender.send(
                text: text,
                workspaceId: session.cmuxWorkspaceId,
                surfaceId: session.cmuxSurfaceId
            )
            if !ok {
                // Surface a hint so the user knows the programmatic send
                // failed; fall through to clipboard so they can paste.
                await MainActor.run {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        inputHintText = L10n.copiedPasteInTerminal
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        inputHintText = nil
                    }
                }
            }
            return
        }

        guard session.isInTmux else {
            // Not in tmux. Prefer AppleScript-based sending (Terminal.app,
            // iTerm2) because TIOCSTI is restricted on recent macOS and
            // the TTY-injection path silently fails there. If the terminal
            // doesn't expose a scriptable API or the tty can't be matched,
            // fall through to the legacy TIOCSTI attempt, and finally to
            // the clipboard+focus hint.
            let sentViaAppleScript = await TerminalTextSender.send(text: text, session: session)
            if sentViaAppleScript {
                return
            }

            if let tty = session.tty {
                let ok = await sendViaTTY(text, tty: tty)
                if !ok {
                    // Fallback: clipboard + focus
                    await MainActor.run {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(text, forType: .string)
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            inputHintText = L10n.copiedPasteInTerminal
                        }
                    }
                    focusTerminal()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            inputHintText = nil
                        }
                    }
                }
            }
            return
        }
        guard let pid = session.pid else { return }

        if let target = await TmuxController.shared.findTmuxTarget(forClaudePid: pid) {
            _ = await ToolApprovalHandler.shared.sendMessage(text, to: target)
        }
    }

    /// Send text to a TTY device using TIOCSTI ioctl (injects as keyboard input).
    /// Works for non-tmux terminal sessions where we know the TTY path.
    private func sendViaTTY(_ text: String, tty: String) async -> Bool {
        // Ensure tty path is a full device path
        let ttyPath = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"

        // Use a small Python script to inject chars via TIOCSTI ioctl.
        // Each character is injected individually into the TTY input queue,
        // then a newline is sent to submit.
        let script = """
import os, fcntl, termios, struct, sys, base64
tty_path = sys.argv[1]
text = base64.b64decode(sys.argv[2]).decode('utf-8')
try:
    fd = os.open(tty_path, os.O_RDWR)
    for ch in text:
        for b in ch.encode('utf-8'):
            fcntl.ioctl(fd, termios.TIOCSTI, struct.pack('B', b))
    # Send Enter (newline)
    fcntl.ioctl(fd, termios.TIOCSTI, struct.pack('B', 10))
    os.close(fd)
except Exception as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
"""

        let b64 = Data(text.utf8).base64EncodedString()

        do {
            _ = try await ProcessExecutor.shared.run(
                "/usr/bin/python3",
                arguments: ["-c", script, ttyPath, b64]
            )
            return true
        } catch {
            return false
        }
    }

    private var openCodeServerSessionId: String? {
        guard isOpenCodeSession else { return nil }
        return session.opencodeRawSessionId
    }

    private func sendToOpenCode(_ text: String) async -> (success: Bool, hint: String?) {
        if let result = await sendToOpenCodeControlSocket(text) {
            return result
        }

        // Fallback to HTTP server if the OpenCode instance is exposing one.
        return await sendToOpenCodeHTTP(text)
    }

    private func sendToOpenCodeControlSocket(_ text: String) async -> (success: Bool, hint: String?)? {
        guard let sid = openCodeServerSessionId else {
            return (false, "no session id")
        }
        guard let socketPath = session.openCodeControlSocketPath else {
            return (false, "no control socket (restart opencode)")
        }

        let body: [String: Any] = [
            "type": "prompt",
            "session_id": sid,
            "text": text,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return (false, "bad payload")
        }

        guard let data = await UnixSocketClient.sendAndReceive(
            socketPath: socketPath,
            payload: payload,
            timeoutSeconds: 2,
            allowNoResponse: true
        ) else {
            return (false, "control socket unreachable")
        }

        // Best-effort: if the control socket accepted the payload but didn't reply in time,
        // treat it as success (the prompt may still have been queued).
        if data.isEmpty {
            return (true, nil)
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, "bad control response")
        }

        if let ok = obj["ok"] as? Bool, ok {
            return (true, nil)
        }

        if let err = obj["error"] as? String, !err.isEmpty {
            return (false, err)
        }

        return (false, "control failed")
    }

    private func sendToOpenCodeHTTP(_ text: String) async -> (success: Bool, hint: String?) {
        guard let sid = openCodeServerSessionId else {
            return (false, "no session id")
        }
        guard let port = session.serverPort else {
            return (false, "no server info (restart opencode)")
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = (session.serverHostname?.isEmpty == false) ? session.serverHostname : "localhost"
        components.port = port
        // Use prompt_async to avoid blocking until completion.
        components.path = "/session/\(sid)/prompt_async"

        guard let url = components.url else { return (false, "invalid server url") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "parts": [[
                "type": "text",
                "text": text,
            ]]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return (false, "bad payload")
        }
        request.httpBody = data

        do {
            let (_, resp) = try await URLSession.shared.data(for: request)
            if let http = resp as? HTTPURLResponse {
                // prompt_async returns 204 on success.
                if (200..<300).contains(http.statusCode) {
                    return (true, nil)
                }
                return (false, "OpenCode API HTTP \(http.statusCode)")
            }
        } catch {
            return (false, "OpenCode API unreachable")
        }

        return (false, "unexpected response")
    }
}

// MARK: - Display Grouping

/// Display unit for the chat list. Either a single history item, or a merged
/// group of consecutive same-name tool calls.
enum ChatDisplayItem: Identifiable {
    case single(ChatHistoryItem)
    case mergedTools(id: String, name: String, items: [ChatHistoryItem])

    var id: String {
        switch self {
        case .single(let item): return item.id
        case .mergedTools(let id, _, _): return id
        }
    }
}

/// Whether a history item has no user-visible content and should be hidden
/// entirely (e.g., empty assistant text blocks emitted between tool calls).
private func isEmptyTextItem(_ item: ChatHistoryItem) -> Bool {
    func isBlank(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    switch item.type {
    case .user(let t), .assistant(let t), .thinking(let t):
        return isBlank(t)
    case .toolCall, .image, .interrupted:
        return false
    }
}

/// Merge consecutive tool calls of the same name. Running / waiting-for-approval
/// tools and Task tools are excluded — they always render as their own entry.
/// Empty text items are dropped so they neither render as blank rows nor break
/// the merging of tools that surround them.
func groupChatItems(_ items: [ChatHistoryItem]) -> [ChatDisplayItem] {
    let visible = items.filter { !isEmptyTextItem($0) }
    var result: [ChatDisplayItem] = []
    var buffer: [ChatHistoryItem] = []
    var bufferName: String? = nil

    func flush() {
        if buffer.count >= 2, let name = bufferName, let first = buffer.first {
            result.append(.mergedTools(id: "merged-\(name)-\(first.id)", name: name, items: buffer))
        } else {
            for item in buffer { result.append(.single(item)) }
        }
        buffer.removeAll(keepingCapacity: true)
        bufferName = nil
    }

    for item in visible {
        if case .toolCall(let tool) = item.type,
           tool.status != .running,
           tool.status != .waitingForApproval,
           !tool.isSubagentContainer {
            if tool.name == bufferName {
                buffer.append(item)
            } else {
                flush()
                buffer.append(item)
                bufferName = tool.name
            }
        } else {
            flush()
            result.append(.single(item))
        }
    }
    flush()
    return result
}

// MARK: - Display Item Dispatcher

struct ChatDisplayItemView: View {
    let displayItem: ChatDisplayItem
    let sessionId: String

    var body: some View {
        switch displayItem {
        case .single(let item):
            MessageItemView(item: item, sessionId: sessionId)
        case .mergedTools(_, _, let items):
            MergedToolCallView(items: items, sessionId: sessionId)
        }
    }
}

// MARK: - Message Item View

struct MessageItemView: View {
    let item: ChatHistoryItem
    let sessionId: String

    var body: some View {
        switch item.type {
        case .user(let text):
            UserMessageView(text: text)
        case .assistant(let text):
            AssistantMessageView(text: text)
        case .toolCall(let tool):
            ToolCallView(tool: tool, sessionId: sessionId)
        case .thinking(let text):
            ThinkingView(text: text)
        case .image(let block):
            ImageMessageView(image: block)
        case .interrupted:
            InterruptedMessageView()
        }
    }
}

// MARK: - User Message

struct UserMessageView: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 60)

            MarkdownText(text, color: .primary, fontSize: 13)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.white.opacity(0.15))
                )
        }
    }
}

// MARK: - Assistant Message

struct AssistantMessageView: View {
    let text: String

    var body: some View {
        // Skip rendering when text is empty — otherwise the dot indicator
        // shows up alone (orphan dot) for tool-only assistant turns.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 6) {
                // White dot indicator
                Circle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)

                MarkdownText(text, color: .primary.opacity(0.9), fontSize: 13)

                Spacer(minLength: 60)
            }
        }
    }
}

// MARK: - Processing Indicator

struct ProcessingIndicatorView: View {
    private let baseTexts = [L10n.processing, L10n.working]
    private let color = Color(red: 0.85, green: 0.47, blue: 0.34) // Claude orange
    private let baseText: String

    @State private var dotCount: Int = 1
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    /// Use a turnId to select text consistently per user turn
    init(turnId: String = "") {
        // Use hash of turnId to pick base text consistently for this turn
        let index = abs(turnId.hashValue) % baseTexts.count
        baseText = baseTexts[index]
    }

    private var dots: String {
        String(repeating: ".", count: dotCount)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            ProcessingSpinner()
                .frame(width: 6)

            Text(baseText + dots)
                .font(.system(size: 13))
                .foregroundColor(color)

            Spacer()
        }
        .onReceive(timer) { _ in
            dotCount = (dotCount % 3) + 1
        }
    }
}

// MARK: - Tool Call View

struct ToolCallView: View {
    let tool: ToolCallItem
    let sessionId: String

    @State private var pulseOpacity: Double = 0.6
    @State private var isExpanded: Bool = false
    @State private var isHovering: Bool = false

    private var statusColor: Color {
        switch tool.status {
        case .running:
            return Color.primary
        case .waitingForApproval:
            return Color.orange
        case .success:
            return Color.green
        case .error, .interrupted:
            return Color.red
        }
    }

    private var textColor: Color {
        switch tool.status {
        case .running:
            return .primary.opacity(0.6)
        case .waitingForApproval:
            return Color.orange.opacity(0.9)
        case .success:
            return .primary.opacity(0.7)
        case .error, .interrupted:
            return Color.red.opacity(0.8)
        }
    }

    private var toolNameColor: Color {
        MCPToolFormatter.color(for: tool.name)
    }

    private var hasResult: Bool {
        tool.result != nil || tool.structuredResult != nil
    }

    /// Whether the tool can be expanded (has result, NOT a subagent container, NOT Edit tools)
    private var canExpand: Bool {
        !tool.isSubagentContainer && tool.name != "Edit" && hasResult
    }

    private var showContent: Bool {
        tool.name == "Edit" || isExpanded
    }

    private var agentDescription: String? {
        guard tool.name == "AgentOutputTool",
              let agentId = tool.input["agentId"],
              let sessionDescriptions = ChatHistoryManager.shared.agentDescriptions[sessionId] else {
            return nil
        }
        return sessionDescriptions[agentId]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor.opacity(tool.status == .running || tool.status == .waitingForApproval ? pulseOpacity : 0.6))
                    .frame(width: 6, height: 6)
                    .id(tool.status)  // Forces view recreation, cancelling repeatForever animation
                    .onAppear {
                        if tool.status == .running || tool.status == .waitingForApproval {
                            startPulsing()
                        }
                    }

                Text(MCPToolFormatter.formatToolName(tool.name))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(tool.status == .error || tool.status == .interrupted ? textColor : toolNameColor)
                    .fixedSize()

                if tool.isSubagentContainer && !tool.subagentTools.isEmpty {
                    let taskDesc = tool.input["description"] ?? L10n.processing + "..."
                    Text(L10n.runningAgent(description: taskDesc, toolCount: tool.subagentTools.count))
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if tool.name == "AgentOutputTool", let desc = agentDescription {
                    let blocking = tool.input["block"] == "true"
                    Text(blocking ? "Waiting: \(desc)" : desc)
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if let preview = MCPToolFormatter.previewText(toolName: tool.name, input: tool.input) {
                    // Tool-specific preview (Bash command, Read path, Grep
                    // pattern, MCP args, …). Shown even while the tool is
                    // still running so realtime rows aren't just a generic
                    // status label.
                    Text(preview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(tool.statusDisplay.text)
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                // Expand indicator (only for expandable tools)
                if canExpand && tool.status != .running && tool.status != .waitingForApproval {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.primary.opacity(0.3))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
                }
            }

            // Subagent tools list (for Task/Agent tools)
            if tool.isSubagentContainer && !tool.subagentTools.isEmpty {
                SubagentToolsList(tools: tool.subagentTools)
                    .padding(.leading, 12)
                    .padding(.top, 2)
            }

            // Result content (Edit always shows, others when expanded)
            // Edit tools bypass hasResult check - fallback in ToolResultContent renders from input params
            if showContent && tool.status != .running && !tool.isSubagentContainer && (hasResult || tool.name == "Edit") {
                ToolResultContent(tool: tool)
                    .padding(.leading, 12)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Edit tools show diff from input even while running
            if tool.name == "Edit" && tool.status == .running {
                EditInputDiffView(input: tool.input)
                    .padding(.leading, 12)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(canExpand && isHovering ? Color.white.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            if canExpand {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
    }

    private func startPulsing() {
        withAnimation(
            .easeInOut(duration: 0.6)
            .repeatForever(autoreverses: true)
        ) {
            pulseOpacity = 0.15
        }
    }
}

// MARK: - Merged Tool Call View

/// Renders a group of consecutive same-name tool calls as a single collapsible
/// row ("Read × 3"). Expanded state shows each tool's preview and result in
/// chronological order.
struct MergedToolCallView: View {
    let items: [ChatHistoryItem]
    let sessionId: String

    @State private var isExpanded: Bool = false
    @State private var isHovering: Bool = false

    private var tools: [ToolCallItem] {
        items.compactMap {
            if case .toolCall(let tool) = $0.type { return tool }
            return nil
        }
    }

    private var toolName: String { tools.first?.name ?? "" }

    /// Worst-case status across all merged tools.
    private var aggregatedStatus: ToolStatus {
        if tools.contains(where: { $0.status == .error }) { return .error }
        if tools.contains(where: { $0.status == .interrupted }) { return .interrupted }
        return .success
    }

    private var statusColor: Color {
        switch aggregatedStatus {
        case .success: return Color.green
        case .error, .interrupted: return Color.red
        default: return Color.primary
        }
    }

    private var textColor: Color {
        switch aggregatedStatus {
        case .success: return .primary.opacity(0.7)
        case .error, .interrupted: return Color.red.opacity(0.8)
        default: return .primary.opacity(0.7)
        }
    }

    private var toolNameColor: Color {
        MCPToolFormatter.color(for: toolName)
    }

    private func subItemDotColor(_ status: ToolStatus) -> Color {
        switch status {
        case .success: return Color.green
        case .error, .interrupted: return Color.red
        default: return Color.primary
        }
    }

    private func hasContent(_ tool: ToolCallItem) -> Bool {
        tool.result != nil || tool.structuredResult != nil || tool.name == "Edit"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor.opacity(0.6))
                    .frame(width: 6, height: 6)

                Text(MCPToolFormatter.formatToolName(toolName))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(aggregatedStatus == .error || aggregatedStatus == .interrupted ? textColor : toolNameColor)
                    .fixedSize()

                Text("× \(tools.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(textColor.opacity(0.7))

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.primary.opacity(0.3))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(subItemDotColor(tool.status).opacity(0.6))
                                    .frame(width: 4, height: 4)
                                Text(tool.statusDisplay.text)
                                    .font(.system(size: 11))
                                    .foregroundColor(.primary.opacity(0.65))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            if hasContent(tool) {
                                ToolResultContent(tool: tool)
                                    .padding(.leading, 10)
                                    .padding(.top, 2)
                            }
                        }
                    }
                }
                .padding(.leading, 12)
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.white.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
    }
}

// MARK: - Subagent Views

/// List of subagent tools (shown during Task execution)
struct SubagentToolsList: View {
    let tools: [SubagentToolCall]

    /// Number of hidden tools (all except last 2)
    private var hiddenCount: Int {
        max(0, tools.count - 2)
    }

    /// Recent tools to show (last 2, regardless of status)
    private var recentTools: [SubagentToolCall] {
        Array(tools.suffix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Show count of older hidden tools at top
            if hiddenCount > 0 {
                Text(L10n.moreToolUses(hiddenCount))
                    .font(.system(size: 10))
                    .foregroundColor(.primary.opacity(0.4))
            }

            // Show last 2 tools (most recent activity)
            ForEach(recentTools) { tool in
                SubagentToolRow(tool: tool)
            }
        }
    }
}

/// Single subagent tool row
struct SubagentToolRow: View {
    let tool: SubagentToolCall

    @State private var dotOpacity: Double = 0.5

    private var statusColor: Color {
        switch tool.status {
        case .running, .waitingForApproval: return .orange
        case .success: return .green
        case .error, .interrupted: return .red
        }
    }

    /// Get status text using the same logic as regular tools
    private var statusText: String {
        if tool.status == .interrupted {
            return L10n.interrupted
        } else if tool.status == .running {
            return ToolStatusDisplay.running(for: tool.name, input: tool.input).text
        } else {
            // For completed subagent tools, we don't have the result data
            // so use a simple display based on tool name and input
            return ToolStatusDisplay.running(for: tool.name, input: tool.input).text
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            // Status dot
            Circle()
                .fill(statusColor.opacity(tool.status == .running ? dotOpacity : 0.6))
                .frame(width: 4, height: 4)
                .id(tool.status)  // Forces view recreation, cancelling repeatForever animation
                .onAppear {
                    if tool.status == .running {
                        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                            dotOpacity = 0.2
                        }
                    }
                }

            // Tool name
            Text(tool.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.primary.opacity(0.6))

            // Status text (same format as regular tools)
            Text(statusText)
                .font(.system(size: 10))
                .foregroundColor(.primary.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Summary of subagent tools (shown when Task is expanded after completion)
struct SubagentToolsSummary: View {
    let tools: [SubagentToolCall]

    private var toolCounts: [(String, Int)] {
        var counts: [String: Int] = [:]
        for tool in tools {
            counts[tool.name, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.subagentUsedTools(tools.count))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.primary.opacity(0.5))

            HStack(spacing: 8) {
                ForEach(toolCounts.prefix(5), id: \.0) { name, count in
                    HStack(spacing: 2) {
                        Text(name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.primary.opacity(0.4))
                        Text("×\(count)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.primary.opacity(0.3))
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.03))
        )
    }
}

// MARK: - Thinking View

struct ThinkingView: View {
    let text: String

    @State private var isExpanded = false

    private var canExpand: Bool {
        text.count > 80
    }

    var body: some View {
        // Skip rendering when text is empty — streaming thinking blocks can
        // briefly arrive empty, which otherwise leaves an orphan grey dot.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .padding(.top, 4)

                Text(isExpanded ? text : String(text.prefix(80)) + (canExpand ? "..." : ""))
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .italic()
                    .lineLimit(isExpanded ? nil : 1)
                    .multilineTextAlignment(.leading)

                Spacer()

                if canExpand {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.gray.opacity(0.5))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .padding(.top, 3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if canExpand {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Image Message

struct ImageMessageView: View {
    let image: ImageBlock

    /// Decoded image cached so base64 isn't re-decoded on every render.
    /// Large inline images (tens of KB) would otherwise thrash during
    /// scrolling or parent re-renders.
    @State private var decoded: NSImage?

    var body: some View {
        HStack {
            Spacer(minLength: 60)

            if let decoded {
                Image(nsImage: decoded)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 280, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            } else {
                // Decode failed / pending — labelled placeholder rather than silently dropping
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 12))
                    Text("Image (\(image.mediaType))")
                        .font(.system(size: 12))
                }
                .foregroundColor(.primary.opacity(0.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.08))
                )
            }
        }
        .task(id: image.id) {
            // Decode off the main thread so large images don't hitch scrolling.
            let b64 = image.base64Data
            let decoded = await Task.detached(priority: .userInitiated) {
                guard let data = Data(base64Encoded: b64) else { return nil as NSImage? }
                return NSImage(data: data)
            }.value
            self.decoded = decoded
        }
    }
}

// MARK: - Interrupted Message

struct InterruptedMessageView: View {
    var body: some View {
        HStack {
            Text(L10n.interrupted)
                .font(.system(size: 13))
                .foregroundColor(.red)
            Spacer()
        }
    }
}

// MARK: - Claude Code Question Bar

/// Bar for Claude Code AskUserQuestion — supports both free text and option selection
struct ClaudeCodeQuestionBar: View {
    let question: String?
    let options: [String]
    let onSubmit: (String) -> Void
    let onGoToTerminal: () -> Void

    @Environment(\.isNotchMode) private var isNotchMode
    @State private var answerText: String = ""
    @State private var selectedOption: Int? = nil
    @FocusState private var isFocused: Bool

    private var hasOptions: Bool { !options.isEmpty }
    private var trimmedAnswer: String { answerText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let question, !question.isEmpty {
                Text(question)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
                    .padding(.horizontal, 16)
            } else {
                Text(L10n.claudeCodeNeedsInput)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary.opacity(0.6))
                    .padding(.horizontal, 16)
            }

            if hasOptions {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                            Button {
                                selectedOption = index
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(selectedOption == index ? Color.white.opacity(0.9) : Color.white.opacity(0.15))
                                        .frame(width: 8, height: 8)
                                    Text(option)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(selectedOption == index ? .white.opacity(0.95) : .white.opacity(0.7))
                                        .lineLimit(2)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(selectedOption == index ? 0.12 : 0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(maxHeight: 150)

                HStack(spacing: 8) {
                    Spacer()
                    terminalButton

                    Button {
                        if let idx = selectedOption, idx < options.count {
                            onSubmit(options[idx])
                        }
                    } label: {
                        Text(L10n.submit)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor({
                                if selectedOption == nil {
                                    return isNotchMode ? Color.white.opacity(0.3) : Color.secondary
                                }
                                return isNotchMode ? .black : .white
                            }())
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background({
                                if selectedOption == nil {
                                    return Color.white.opacity(0.1)
                                }
                                return isNotchMode ? Color.white.opacity(0.95) : Color.accentColor
                            }())
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedOption == nil)
                }
                .padding(.horizontal, 16)
            } else {
                HStack(spacing: 8) {
                    TextField(L10n.typeAnswer, text: $answerText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .focused($isFocused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onSubmit { submitFreeText() }

                    terminalButton

                    Button { submitFreeText() } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor({
                                if trimmedAnswer.isEmpty {
                                    return isNotchMode ? Color.white.opacity(0.3) : Color.secondary
                                }
                                return isNotchMode ? .black : .white
                            }())
                            .frame(width: 30, height: 30)
                            .background({
                                if trimmedAnswer.isEmpty {
                                    return Color.white.opacity(0.1)
                                }
                                return isNotchMode ? Color.white.opacity(0.95) : Color.accentColor
                            }())
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmedAnswer.isEmpty)
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 12)
        .background(isNotchMode ? Color.black.opacity(0.2) : Color.white.opacity(0.05))
        .onAppear { if !hasOptions { isFocused = true } }
    }

    private var terminalButton: some View {
        Button { onGoToTerminal() } label: {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary.opacity(0.6))
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func submitFreeText() {
        let text = answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        answerText = ""
        onSubmit(text)
    }
}

// MARK: - Chat Approval Bar

/// Approval bar for the chat view with animated buttons
struct ChatApprovalBar: View {
    let tool: String
    let toolInput: String?
    let allowAlways: Bool
    let onApprove: () -> Void
    let onAlways: () -> Void
    let onDeny: () -> Void

    @Environment(\.isNotchMode) private var isNotchMode
    @State private var showContent = false
    @State private var showAllowButton = false
    @State private var showAlwaysButton = false
    @State private var showDenyButton = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Tool info
            VStack(alignment: .leading, spacing: 2) {
                Text(MCPToolFormatter.formatToolName(tool))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(TerminalColors.amber)
                if let input = toolInput {
                    Text(input)
                        .font(.system(size: 11))
                        .foregroundColor(.primary.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .opacity(showContent ? 1 : 0)
            .offset(x: showContent ? 0 : -10)

            // Buttons row
            HStack(spacing: 8) {
                Spacer()

                // Deny button
                Button {
                    onDeny()
                } label: {
                    Text(L10n.deny)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary.opacity(0.7))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .opacity(showDenyButton ? 1 : 0)
                .scaleEffect(showDenyButton ? 1 : 0.8)

                if allowAlways {
                    Button {
                        onAlways()
                    } label: {
                        Text(L10n.always)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary.opacity(0.8))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.14))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .opacity(showAlwaysButton ? 1 : 0)
                    .scaleEffect(showAlwaysButton ? 1 : 0.8)
                }

                // Allow button
                Button {
                    onApprove()
                } label: {
                    Text(L10n.allow)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isNotchMode ? .black : .white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(isNotchMode ? Color.white.opacity(0.95) : Color.accentColor)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .opacity(showAllowButton ? 1 : 0)
                .scaleEffect(showAllowButton ? 1 : 0.8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isNotchMode ? Color.black.opacity(0.2) : Color.white.opacity(0.05))
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showContent = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.1)) {
                showDenyButton = true
            }
            if allowAlways {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.15)) {
                    showAlwaysButton = true
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.2)) {
                    showAllowButton = true
                }
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.15)) {
                    showAllowButton = true
                }
            }
        }
    }
}

// MARK: - New Messages Indicator

/// Floating indicator showing count of new messages when user has scrolled up
struct NewMessagesIndicator: View {
    let count: Int
    let onTap: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))

                Text(L10n.newMessages(count))
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color(red: 0.85, green: 0.47, blue: 0.34)) // Claude orange
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
            )
            .scaleEffect(isHovering ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                isHovering = hovering
            }
        }
    }
}
