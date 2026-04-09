//
//  ChatView.swift
//  VibeHub
//
//  Redesigned chat interface with clean visual hierarchy
//

import AppKit
import Combine
import SwiftUI

struct ChatView: View {
    let sessionId: String
    let initialSession: SessionState
    let sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel

    @State private var inputText: String = ""
    @State private var history: [ChatHistoryItem] = []
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
                } else {
                    inputBar
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
                    .foregroundColor(.white.opacity(isHeaderHovered ? 1.0 : 0.6))
                    .frame(width: 24, height: 24)

                Text(session.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(isHeaderHovered ? 1.0 : 0.85))
                    .lineLimit(1)

                // Tags
                HStack(spacing: 4) {
                    // Software tag
                    let cliSourceColor: Color = {
                        switch session.cliSource {
                        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
                        case .opencode: return TerminalColors.green
                        case .codex: return TerminalColors.blue
                        }
                    }()
                    Text(session.cliSource.rawValue)
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
        .background(Color.black.opacity(0.2))
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [fadeColor.opacity(0.7), fadeColor.opacity(0)],
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

    /// Get the last user message ID for stable text selection per turn
    private var lastUserMessageId: String {
        for item in history.reversed() {
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
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.2))
            Text(L10n.noMessagesYet)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Message List

    /// Background color for fade gradients
    private let fadeColor = Color(red: 0.00, green: 0.00, blue: 0.00)

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

                    ForEach(history.reversed()) { item in
                        MessageItemView(item: item, sessionId: sessionId)
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
        session.opencodeRawSessionId != nil
    }

    private var isCodexSession: Bool {
        session.codexRawSessionId != nil
    }

    /// Display name of the remote host, if this is a remote session
    private var remoteHostName: String? {
        guard let hostId = session.remoteHostId else { return nil }
        return RemoteManager.shared.hosts.first(where: { $0.id == hostId })?.name
            ?? hostId.prefix(8).description
    }

    /// Can send messages if we can reach the session.
    /// - Claude Code: tmux send-keys (if in tmux) or TTY injection (if tty available).
    /// - OpenCode: control socket / HTTP API / clipboard fallback.
    private var canSendMessages: Bool {
        if session.isRemote {
            return true
        }
        // Claude Code / Codex: either tmux or raw TTY is sufficient
        if !isOpenCodeSession && !isCodexSession {
            return session.tty != nil
        }
        return true // OpenCode always has a path (control socket / HTTP / clipboard)
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
                .foregroundColor(canSendMessages ? .white : .white.opacity(0.4))
                .focused($isInputFocused)
                .onChange(of: isInputFocused) { _, isFocused in
                    if isFocused {
                        viewModel.enterKeyboardMode()
                    }
                }
                .simultaneousGesture(TapGesture().onEnded {
                    viewModel.enterKeyboardMode()
                    // Give the window a tiny moment to become key before forcing focus
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
                    .foregroundColor(!canSendMessages || inputText.isEmpty ? .white.opacity(0.2) : .white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .disabled(!canSendMessages || inputText.isEmpty)
        }
        .overlay(alignment: .topLeading) {
            if let inputHintText {
                Text(inputHintText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.black.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Capsule())
                    .offset(x: 18, y: -10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [fadeColor.opacity(0), fadeColor.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: -24) // Push above input bar
            .allowsHitTesting(false)
        }
        .zIndex(1) // Render above message list
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

        // Don't add to history here - it will be synced from JSONL when UserPromptSubmit event fires
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

        guard session.isInTmux else {
            // Not in tmux - try TTY injection directly
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
        guard let tty = session.tty else { return }

        if let target = await findTmuxTarget(tty: tty) {
            _ = await ToolApprovalHandler.shared.sendMessage(text, to: target)
        }
    }

    private func findTmuxTarget(tty: String) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        do {
            let output = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: ["list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}"]
            )

            let lines = output.components(separatedBy: "\n")
            for line in lines {
                let parts = line.components(separatedBy: " ")
                guard parts.count >= 2 else { continue }

                let target = parts[0]
                let paneTty = parts[1].replacingOccurrences(of: "/dev/", with: "")

                if paneTty == tty {
                    return TmuxTarget(from: target)
                }
            }
        } catch {
            return nil
        }

        return nil
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

            MarkdownText(text, color: .white, fontSize: 13)
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
        HStack(alignment: .top, spacing: 6) {
            // White dot indicator
            Circle()
                .fill(Color.white.opacity(0.6))
                .frame(width: 6, height: 6)
                .padding(.top, 5)

            MarkdownText(text, color: .white.opacity(0.9), fontSize: 13)

            Spacer(minLength: 60)
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
            return Color.white
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
            return .white.opacity(0.6)
        case .waitingForApproval:
            return Color.orange.opacity(0.9)
        case .success:
            return .white.opacity(0.7)
        case .error, .interrupted:
            return Color.red.opacity(0.8)
        }
    }

    private var toolNameColor: Color {
        switch tool.name {
        case "Read":
            return Color.cyan
        case "Edit", "Write", "NotebookEdit":
            return Color.orange
        case "Bash":
            return Color.green
        case "Grep", "Glob":
            return Color.yellow
        case "Agent", "Task":
            return Color.indigo.opacity(0.8)
        case "WebSearch", "WebFetch":
            return Color.blue
        case "AskUserQuestion":
            return Color.mint
        default:
            if MCPToolFormatter.isMCPTool(tool.name) {
                return Color.teal
            }
            return .white.opacity(0.8)
        }
    }

    private var hasResult: Bool {
        tool.result != nil || tool.structuredResult != nil
    }

    /// Whether the tool can be expanded (has result, NOT Task tools, NOT Edit tools)
    private var canExpand: Bool {
        tool.name != "Task" && tool.name != "Edit" && hasResult
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

                if tool.name == "Task" && !tool.subagentTools.isEmpty {
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
                } else if MCPToolFormatter.isMCPTool(tool.name) && !tool.input.isEmpty {
                    Text(MCPToolFormatter.formatArgs(tool.input))
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
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
                        .foregroundColor(.white.opacity(0.3))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
                }
            }

            // Subagent tools list (for Task tools)
            if tool.name == "Task" && !tool.subagentTools.isEmpty {
                SubagentToolsList(tools: tool.subagentTools)
                    .padding(.leading, 12)
                    .padding(.top, 2)
            }

            // Result content (Edit always shows, others when expanded)
            // Edit tools bypass hasResult check - fallback in ToolResultContent renders from input params
            if showContent && tool.status != .running && tool.name != "Task" && (hasResult || tool.name == "Edit") {
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
                    .foregroundColor(.white.opacity(0.4))
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
                .foregroundColor(.white.opacity(0.6))

            // Status text (same format as regular tools)
            Text(statusText)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
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
                .foregroundColor(.white.opacity(0.5))

            HStack(spacing: 8) {
                ForEach(toolCounts.prefix(5), id: \.0) { name, count in
                    HStack(spacing: 2) {
                        Text(name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                        Text("×\(count)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.3))
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
                    .foregroundColor(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
                    .padding(.horizontal, 16)
            } else {
                Text(L10n.claudeCodeNeedsInput)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
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
                            .foregroundColor(selectedOption != nil ? .black : .white.opacity(0.3))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(selectedOption != nil ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
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
                            .foregroundColor(trimmedAnswer.isEmpty ? .white.opacity(0.3) : .black)
                            .frame(width: 30, height: 30)
                            .background(trimmedAnswer.isEmpty ? Color.white.opacity(0.1) : Color.white.opacity(0.95))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmedAnswer.isEmpty)
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .onAppear { if !hasOptions { isFocused = true } }
    }

    private var terminalButton: some View {
        Button { onGoToTerminal() } label: {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
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
                        .foregroundColor(.white.opacity(0.5))
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
                        .foregroundColor(.white.opacity(0.7))
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
                            .foregroundColor(.white.opacity(0.8))
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
                        .foregroundColor(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.95))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .opacity(showAllowButton ? 1 : 0)
                .scaleEffect(showAllowButton ? 1 : 0.8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
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
