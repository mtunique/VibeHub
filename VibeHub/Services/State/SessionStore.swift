//
//  SessionStore.swift
//  VibeHub
//
//  Central state manager for all Claude sessions.
//  Single source of truth - all state mutations flow through process().
//

import Combine
import Foundation
#if !APP_STORE
import Mixpanel
#endif
import os.log

/// Central state manager for all Claude sessions
/// Uses Swift actor for thread-safe state mutations
actor SessionStore {
    static let shared = SessionStore()

    /// Logger for session store (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.vibehub", category: "Session")

    // MARK: - State

    /// All sessions keyed by sessionId
    private var sessions: [String: SessionState] = [:]

    /// OpenCode: ID of the currently streaming assistant message item (per session)
    /// We update this item in-place as new partial text arrives.
    private var opencodeActiveAssistantItemId: [String: String] = [:]

    /// Pending file syncs (debounced)
    private var pendingSyncs: [String: Task<Void, Never>] = [:]

    /// Sync debounce interval (100ms)
    private let syncDebounceNs: UInt64 = 100_000_000

    // MARK: - Published State (for UI)

    /// Publisher for session state changes (nonisolated for Combine subscription from any context)
    private nonisolated(unsafe) let sessionsSubject = CurrentValueSubject<[SessionState], Never>([])

    /// Public publisher for UI subscription
    nonisolated var sessionsPublisher: AnyPublisher<[SessionState], Never> {
        sessionsSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Event Processing

    /// Process any session event - the ONLY way to mutate state
    func process(_ event: SessionEvent) async {
        Self.logger.debug("Processing: \(String(describing: event), privacy: .public)")

        switch event {
        case .hookReceived(let hookEvent):
            await processHookEvent(hookEvent)

        case .permissionApproved(let sessionId, let toolUseId):
            await processPermissionApproved(sessionId: sessionId, toolUseId: toolUseId)

        case .permissionDenied(let sessionId, let toolUseId, let reason):
            await processPermissionDenied(sessionId: sessionId, toolUseId: toolUseId, reason: reason)

        case .permissionSocketFailed(let sessionId, let toolUseId):
            await processSocketFailure(sessionId: sessionId, toolUseId: toolUseId)

        case .fileUpdated(let payload):
            await processFileUpdate(payload)

        case .interruptDetected(let sessionId):
            await processInterrupt(sessionId: sessionId)

        case .clearDetected(let sessionId):
            await processClearDetected(sessionId: sessionId)

        case .sessionEnded(let sessionId):
            await processSessionEnd(sessionId: sessionId)

        case .loadHistory(let sessionId, let cwd):
            await loadHistoryFromFile(sessionId: sessionId, cwd: cwd)

        case .historyLoaded(let sessionId, let messages, let completedTools, let toolResults, let structuredResults, let conversationInfo):
            await processHistoryLoaded(
                sessionId: sessionId,
                messages: messages,
                completedTools: completedTools,
                toolResults: toolResults,
                structuredResults: structuredResults,
                conversationInfo: conversationInfo
            )

        case .toolCompleted(let sessionId, let toolUseId, let result):
            await processToolCompleted(sessionId: sessionId, toolUseId: toolUseId, result: result)

        // MARK: - Subagent Events

        case .subagentStarted(let sessionId, let taskToolId):
            processSubagentStarted(sessionId: sessionId, taskToolId: taskToolId)

        case .subagentToolExecuted(let sessionId, let tool):
            processSubagentToolExecuted(sessionId: sessionId, tool: tool)

        case .subagentToolCompleted(let sessionId, let toolId, let status):
            processSubagentToolCompleted(sessionId: sessionId, toolId: toolId, status: status)

        case .subagentStopped(let sessionId, let taskToolId):
            processSubagentStopped(sessionId: sessionId, taskToolId: taskToolId)

        case .agentFileUpdated:
            // No longer used - subagent tools are populated from JSONL completion
            break
        }

        publishState()
    }

    // MARK: - Hook Event Processing

    private func processHookEvent(_ event: HookEvent) async {
        // Resolve session ID: for OpenCode sessions, deduplicate by PID.
        // If an event arrives with an unknown session ID but we already have
        // an OpenCode session from the same process (same _ppid), redirect
        // the event to the existing session to prevent phantom duplicates.
        let eventCLI = event.supportedCLI
        let sessionId: String = {
            let rawId = event.sessionId
            guard eventCLI == .opencode, sessions[rawId] == nil else {
                return rawId
            }
            let effectivePid = event.pid ?? event.sourcePid
            guard let pid = effectivePid else { return rawId }
            if let existingId = findExistingOpenCodeSession(forPid: pid, excluding: rawId) {
                Self.logger.info("OpenCode dedup: redirecting \(rawId.prefix(24), privacy: .public) → \(existingId.prefix(24), privacy: .public) (pid \(pid))")
                return existingId
            }
            return rawId
        }()

        let isNewSession = sessions[sessionId] == nil
        var session = sessions[sessionId] ?? createSession(from: event, sessionId: sessionId)

        // Track new session in Mixpanel
        #if !APP_STORE
        if isNewSession {
            Mixpanel.mainInstance().track(event: "Session Started")
        }
        #endif

        session.pid = event.pid
        // OpenCode events provide `_ppid` instead of `pid`.
        if session.pid == nil, let sourcePid = event.sourcePid {
            session.pid = sourcePid
        }

        if let pid = session.pid {
            let tree = ProcessTreeBuilder.shared.buildTree()
            session.isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: pid, tree: tree)
        }
        if let tty = event.tty {
            session.tty = tty.replacingOccurrences(of: "/dev/", with: "")
        }

        if let serverPort = event.serverPort {
            session.serverPort = serverPort
        }
        if let serverHostname = event.serverHostname, !serverHostname.isEmpty {
            session.serverHostname = serverHostname
        }
        if let cmuxWorkspaceId = event.cmuxWorkspaceId, !cmuxWorkspaceId.isEmpty {
            session.cmuxWorkspaceId = cmuxWorkspaceId
        }
        if let cmuxSurfaceId = event.cmuxSurfaceId, !cmuxSurfaceId.isEmpty {
            session.cmuxSurfaceId = cmuxSurfaceId
        }

        if let remoteHostId = event.remoteHostId {
            session.remoteHostId = remoteHostId
        }
        if let sshClientPort = event.sshClientPort {
            session.sshClientPort = sshClientPort
        }
        session.lastActivity = Date()

        if event.status == "ended" {
            session.phase = .ended
            sessions[sessionId] = session
            cancelPendingSync(sessionId: sessionId)
            publishState()
            // Remove the session after a delay so UI can show the ended state
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                await self?.processSessionEnd(sessionId: sessionId)
            }
            return
        }

        let newPhase = event.determinePhase()

        // Guard: if Claude Code fires PermissionRequest after approving internally (new behavior),
        // the tool may have already completed via PostToolUse. Don't revert to waitingForApproval.
        let toolAlreadyCompleted: Bool = {
            guard case .waitingForApproval(let ctx) = newPhase, !ctx.toolUseId.isEmpty else { return false }
            return session.chatItems.contains {
                guard $0.id == ctx.toolUseId, case .toolCall(let tool) = $0.type else { return false }
                return tool.status == .success || tool.status == .error || tool.status == .interrupted
            }
        }()

        if !toolAlreadyCompleted && session.phase.canTransition(to: newPhase) {
            session.phase = newPhase
        } else if !toolAlreadyCompleted {
            Self.logger.debug("Invalid transition: \(String(describing: session.phase), privacy: .public) -> \(String(describing: newPhase), privacy: .public), ignoring")
        } else {
            Self.logger.debug("Ignoring late PermissionRequest for already-completed tool")
        }

        if event.event == "PermissionRequest", let toolUseId = event.toolUseId, !toolAlreadyCompleted {
            Self.logger.debug("Setting tool \(toolUseId.prefix(12), privacy: .public) status to waitingForApproval")
            updateToolStatus(in: &session, toolId: toolUseId, status: .waitingForApproval)
        }

        applyNonClaudeMetadata(event: event, session: &session)
        applyOpenCodeChatItems(event: event, session: &session)

        processToolTracking(event: event, session: &session)
        processSubagentTracking(event: event, session: &session)

        if event.event == "Stop" {
            session.subagentState = SubagentState()
        }

        // For remote sessions the hook streams JSONL lines in the event
        // itself. Parse + merge the resulting conversationInfo BEFORE the
        // single publish below so subscribers only re-render once per hook
        // event (previously we published twice — pre-parse and post-parse).
        var parsedRemoteLines: ConversationParser.IncrementalParseResult?
        if let newLines = event.newJsonlLines, !newLines.isEmpty {
            Self.logger.debug("Received \(newLines.count) new JSONL lines from remote hook")
            let result = await ConversationParser.shared.parseLines(
                sessionId: sessionId,
                lines: newLines
            )
            parsedRemoteLines = result

            let newInfo = await ConversationParser.shared.parseContent(newLines.joined(separator: "\n"))
            session.conversationInfo = ConversationInfo(
                summary: newInfo.summary ?? session.conversationInfo.summary,
                lastMessage: newInfo.lastMessage ?? session.conversationInfo.lastMessage,
                lastMessageRole: newInfo.lastMessageRole ?? session.conversationInfo.lastMessageRole,
                lastToolName: newInfo.lastToolName ?? session.conversationInfo.lastToolName,
                firstUserMessage: newInfo.firstUserMessage ?? session.conversationInfo.firstUserMessage,
                lastUserMessageDate: newInfo.lastUserMessageDate ?? session.conversationInfo.lastUserMessageDate
            )
        }

        sessions[sessionId] = session

        if let result = parsedRemoteLines {
            if result.clearDetected {
                await processClearDetected(sessionId: sessionId)
            }
            if !result.newMessages.isEmpty || result.clearDetected {
                await processFileUpdate(FileUpdatePayload(
                    sessionId: sessionId,
                    cwd: event.cwd,
                    messages: result.newMessages,
                    isIncremental: !result.clearDetected,
                    completedToolIds: result.completedToolIds,
                    toolResults: result.toolResults,
                    structuredResults: result.structuredResults
                ))
            }
        }

        if event.shouldSyncFile {
            scheduleFileSync(sessionId: sessionId, cwd: event.cwd)
        }
    }

    private func applyNonClaudeMetadata(event: HookEvent, session: inout SessionState) {
        // Use forwarded metadata for OpenCode or as fallback for Claude
        let isOpenCode = session.source == .opencode

        var summary = session.conversationInfo.summary
        var lastMessage = session.conversationInfo.lastMessage
        var lastMessageRole = session.conversationInfo.lastMessageRole
        var lastToolName = session.conversationInfo.lastToolName
        var firstUserMessage = session.conversationInfo.firstUserMessage
        var lastUserMessageDate = session.conversationInfo.lastUserMessageDate

        // Larger upper bound on lastMessage so the 2-line description row
        // in ClaudeInstancesView actually has content to wrap into — 80 was
        // barely enough for 1 line and baked a literal "..." suffix into
        // the data, which killed the second line. Downstream views clamp
        // tighter if they need it.
        if let title = event.sessionTitle, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            summary = truncateInline(title, maxLength: 80)
        }

        if let prompt = event.prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let clean = truncateInline(prompt, maxLength: 240)
            lastMessage = clean
            lastMessageRole = "user"
            lastUserMessageDate = Date()
            if firstUserMessage == nil {
                firstUserMessage = truncateInline(prompt, maxLength: 50)
            }
        }

        if event.event == "PreToolUse", let tool = event.tool {
            lastMessageRole = "tool"
            lastToolName = tool
            // Keep lastMessage as-is; list row uses pendingToolInput for approvals.
        }

        if let assistant = event.lastAssistantMessage, !assistant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastMessage = truncateInline(assistant, maxLength: 240)
            lastMessageRole = "assistant"
        }

        // Apply only if something changed
        if isOpenCode || event.sessionTitle != nil || event.prompt != nil || event.event == "PreToolUse" || event.lastAssistantMessage != nil {
            session.conversationInfo = ConversationInfo(
                summary: summary,
                lastMessage: lastMessage,
                lastMessageRole: lastMessageRole,
                lastToolName: lastToolName,
                firstUserMessage: firstUserMessage,
                lastUserMessageDate: lastUserMessageDate
            )
        }
    }

    private func applyOpenCodeChatItems(event: HookEvent, session: inout SessionState) {
        guard session.source == .opencode else { return }

        let now = Date()

        if event.event == "UserPromptSubmit",
           let prompt = event.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty {
            // New user turn starts a new assistant stream.
            opencodeActiveAssistantItemId[session.sessionId] = nil

            // De-dupe: check recent items for an existing user message with the same text.
            // After SQLite history load, the matching item may not be the very last one.
            let recentItems = session.chatItems.suffix(10)
            if recentItems.contains(where: { item in
                if case .user(let text) = item.type { return text == prompt }
                return false
            }) {
                return
            }

            session.chatItems.append(
                ChatHistoryItem(
                    id: "opencode-user-\(UUID().uuidString)",
                    type: .user(prompt),
                    timestamp: now
                )
            )
        }

        // OpenCode assistant streaming: we receive partial text via last_assistant_message.
        if (event.event == "AssistantMessage" || event.event == "Stop"),
           let text = event.lastAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            let activeId = opencodeActiveAssistantItemId[session.sessionId]

            if let activeId,
               let idx = session.chatItems.firstIndex(where: { $0.id == activeId }),
               case .assistant = session.chatItems[idx].type {
                session.chatItems[idx] = ChatHistoryItem(
                    id: activeId,
                    type: .assistant(text),
                    timestamp: session.chatItems[idx].timestamp
                )
            } else {
                // De-dupe: if the last assistant item already has the same (or longer) text,
                // this is a stale event after SQLite history load — skip it.
                if let lastAssistant = session.chatItems.last(where: { item in
                    if case .assistant = item.type { return true }
                    return false
                }), case .assistant(let existing) = lastAssistant.type,
                   text.count <= existing.count, existing.hasPrefix(text) {
                    return
                }

                let id = "opencode-assistant-\(UUID().uuidString)"
                opencodeActiveAssistantItemId[session.sessionId] = id
                session.chatItems.append(
                    ChatHistoryItem(
                        id: id,
                        type: .assistant(text),
                        timestamp: now
                    )
                )
            }

            // Stop means the turn is done; finalize the assistant item.
            if event.event == "Stop" {
                opencodeActiveAssistantItemId[session.sessionId] = nil
            }
        }
    }

    private func truncateInline(_ s: String?, maxLength: Int) -> String? {
        guard let s else { return nil }
        let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if cleaned.count > maxLength {
            return String(cleaned.prefix(maxLength - 3)) + "..."
        }
        return cleaned
    }

    private func createSession(from event: HookEvent, sessionId: String? = nil) -> SessionState {
        SessionState(
            sessionId: sessionId ?? event.sessionId,
            cwd: event.cwd,
            projectName: URL(fileURLWithPath: event.cwd).lastPathComponent,
            source: event.supportedCLI,
            pid: event.pid,
            tty: event.tty?.replacingOccurrences(of: "/dev/", with: ""),
            isInTmux: false,  // Will be updated
            serverPort: event.serverPort,
            serverHostname: event.serverHostname,
            remoteHostId: event.remoteHostId,
            phase: .idle
        )
    }

    private func processToolTracking(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "PreToolUse":
            if let toolUseId = event.toolUseId, let toolName = event.tool {
                session.toolTracker.startTool(id: toolUseId, name: toolName)

                // Skip creating top-level placeholder for subagent tools
                // They'll appear under their parent Task instead
                let isSubagentTool = session.subagentState.hasActiveSubagent && !ToolCallItem.isSubagentContainerName(toolName)
                if isSubagentTool {
                    return
                }

                let toolExists = session.chatItems.contains { $0.id == toolUseId }
                if !toolExists {
                    var input: [String: String] = [:]
                    if let hookInput = event.toolInput {
                        for (key, value) in hookInput {
                            if let str = value.value as? String {
                                input[key] = str
                            } else if let num = value.value as? Int {
                                input[key] = String(num)
                            } else if let bool = value.value as? Bool {
                                input[key] = bool ? "true" : "false"
                            }
                        }
                    }

                    let placeholderItem = ChatHistoryItem(
                        id: toolUseId,
                        type: .toolCall(ToolCallItem(
                            name: toolName,
                            input: input,
                            status: .running,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: Date()
                    )
                    session.chatItems.append(placeholderItem)
                    Self.logger.debug("Created placeholder tool entry for \(toolUseId.prefix(16), privacy: .public)")
                }
            }

        case "PostToolUse":
            if let toolUseId = event.toolUseId {
                session.toolTracker.completeTool(id: toolUseId, success: true)
                // Check if this tool was waiting for approval (approved in terminal, not VibeHub)
                let wasWaitingForApproval = session.chatItems.contains {
                    guard $0.id == toolUseId, case .toolCall(let t) = $0.type else { return false }
                    return t.status == .waitingForApproval
                }
                // Update chatItem status - tool completed
                for i in 0..<session.chatItems.count {
                    if session.chatItems[i].id == toolUseId,
                       case .toolCall(var tool) = session.chatItems[i].type,
                       tool.status == .waitingForApproval || tool.status == .running {
                        tool.status = .success
                        session.chatItems[i] = ChatHistoryItem(
                            id: toolUseId,
                            type: .toolCall(tool),
                            timestamp: session.chatItems[i].timestamp
                        )
                        break
                    }
                }
                // If this tool was approved in the terminal, transition phase like processPermissionApproved
                if wasWaitingForApproval, case .waitingForApproval = session.phase {
                    if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
                        let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                            toolUseId: nextPending.id,
                            toolName: nextPending.name,
                            toolInput: nil,
                            receivedAt: nextPending.timestamp
                        ))
                        if session.phase.canTransition(to: newPhase) {
                            session.phase = newPhase
                        }
                    } else if session.phase.canTransition(to: .processing) {
                        session.phase = .processing
                    }
                }
            }

        default:
            break
        }
    }

    private func processSubagentTracking(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "PreToolUse":
            if ToolCallItem.isSubagentContainerName(event.tool), let toolUseId = event.toolUseId {
                let description = event.toolInput?["description"]?.value as? String
                session.subagentState.startTask(taskToolId: toolUseId, description: description)
                Self.logger.debug("Started Task/Agent subagent tracking: \(toolUseId.prefix(12), privacy: .public)")
            }

        case "PostToolUse":
            if ToolCallItem.isSubagentContainerName(event.tool), let toolUseId = event.toolUseId {
                // Agent tool returned — the subagent has finished. Stop
                // tracking so subsequent tools in the parent turn don't get
                // attached to this dead task.
                session.subagentState.stopTask(taskToolId: toolUseId)
                Self.logger.debug("Stopped subagent tracking for \(toolUseId.prefix(12), privacy: .public)")
            }

        case "SubagentStop":
            // SubagentStop fires when a subagent completes - stop tracking
            // Subagent tools are populated from agent file in processFileUpdated
            Self.logger.debug("SubagentStop received")

        default:
            break
        }
    }

    // MARK: - Subagent Event Handlers

    /// Handle subagent started event
    private func processSubagentStarted(sessionId: String, taskToolId: String) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.startTask(taskToolId: taskToolId)
        sessions[sessionId] = session
    }

    /// Handle subagent tool executed event
    private func processSubagentToolExecuted(sessionId: String, tool: SubagentToolCall) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.addSubagentTool(tool)
        sessions[sessionId] = session
    }

    /// Handle subagent tool completed event
    private func processSubagentToolCompleted(sessionId: String, toolId: String, status: ToolStatus) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.updateSubagentToolStatus(toolId: toolId, status: status)
        sessions[sessionId] = session
    }

    /// Handle subagent stopped event
    private func processSubagentStopped(sessionId: String, taskToolId: String) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.stopTask(taskToolId: taskToolId)
        sessions[sessionId] = session
        // Subagent tools will be populated from agent file in processFileUpdated
    }

    /// Parse ISO8601 timestamp string
    private func parseTimestamp(_ timestampStr: String?) -> Date? {
        guard let str = timestampStr else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str)
    }

    // MARK: - Permission Processing

    private func processPermissionApproved(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .running)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,  // We don't have the input stored in chatItems
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The approved tool wasn't the one in phase context, but no others pending
                // This can happen if tools were approved out of order
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[sessionId] = session
    }

    // MARK: - Tool Completion Processing

    /// Process a tool completion event (from JSONL detection)
    /// This is the authoritative handler for tool completions - ensures consistent state updates
    private func processToolCompleted(sessionId: String, toolUseId: String, result: ToolCompletionResult) async {
        guard var session = sessions[sessionId] else { return }

        // Check if this tool is already completed (avoid duplicate processing)
        if let existingItem = session.chatItems.first(where: { $0.id == toolUseId }),
           case .toolCall(let tool) = existingItem.type,
           tool.status == .success || tool.status == .error || tool.status == .interrupted {
            // Already completed, skip
            return
        }

        // Update the tool status
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolUseId,
               case .toolCall(var tool) = session.chatItems[i].type {
                tool.status = result.status
                tool.result = result.result
                tool.structuredResult = result.structuredResult
                session.chatItems[i] = ChatHistoryItem(
                    id: toolUseId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                Self.logger.debug("Tool \(toolUseId.prefix(12), privacy: .public) completed with status: \(String(describing: result.status), privacy: .public)")
                break
            }
        }

        // Update session phase if needed
        // If the completed tool was the one in the phase context, switch to next pending or processing
        if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
            if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
                let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                    toolUseId: nextPending.id,
                    toolName: nextPending.name,
                    toolInput: nil,
                    receivedAt: nextPending.timestamp
                ))
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after completion: \(nextPending.id.prefix(12), privacy: .public)")
            } else {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[sessionId] = session
    }

    /// Find the next tool waiting for approval (excluding a specific tool ID)
    private func findNextPendingTool(in session: SessionState, excluding toolId: String) -> (id: String, name: String, timestamp: Date)? {
        for item in session.chatItems {
            if item.id == toolId { continue }
            if case .toolCall(let tool) = item.type, tool.status == .waitingForApproval {
                return (id: item.id, name: tool.name, timestamp: item.timestamp)
            }
        }
        return nil
    }

    private func processPermissionDenied(sessionId: String, toolUseId: String, reason: String?) async {
        guard var session = sessions[sessionId] else { return }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after denial: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing (Claude will handle denial)
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The denied tool wasn't the one in phase context, but no others pending
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[sessionId] = session
    }

    private func processSocketFailure(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Mark the failed tool's status as error
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - switch to that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after socket failure: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - clear permission state
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                session.phase = .idle
            } else if case .waitingForApproval = session.phase {
                // The failed tool wasn't in phase context, but no others pending
                session.phase = .idle
            }
        }

        sessions[sessionId] = session
    }

    // MARK: - File Update Processing

    private func processFileUpdate(_ payload: FileUpdatePayload) async {
        guard var session = sessions[payload.sessionId] else { return }

        // Update conversationInfo from JSONL (summary, lastMessage, etc.)
        let projectsDir = CLIConfig.forSource(session.source).jsonlProjectsDirRelative ?? ".claude/projects"
        let conversationInfo = await ConversationParser.shared.parse(
            sessionId: payload.sessionId,
            cwd: session.cwd,
            projectsDirRelative: projectsDir
        )
        
        let summary = conversationInfo.summary ?? session.conversationInfo.summary
        let lastMessage = conversationInfo.lastMessage ?? session.conversationInfo.lastMessage
        let lastMessageRole = conversationInfo.lastMessageRole ?? session.conversationInfo.lastMessageRole
        let lastToolName = conversationInfo.lastToolName ?? session.conversationInfo.lastToolName
        let firstUserMessage = conversationInfo.firstUserMessage ?? session.conversationInfo.firstUserMessage
        let lastUserMessageDate = conversationInfo.lastUserMessageDate ?? session.conversationInfo.lastUserMessageDate

        session.conversationInfo = ConversationInfo(
            summary: summary,
            lastMessage: lastMessage,
            lastMessageRole: lastMessageRole,
            lastToolName: lastToolName,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: lastUserMessageDate
        )

        // Handle /clear reconciliation - remove items that no longer exist in parser state
        if session.needsClearReconciliation {
            // Build set of valid IDs from the payload messages
            var validIds = Set<String>()
            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    switch block {
                    case .toolUse(let tool):
                        validIds.insert(tool.id)
                    case .text, .thinking, .interrupted:
                        let itemId = "\(message.id)-\(block.typePrefix)-\(blockIndex)"
                        validIds.insert(itemId)
                    }
                }
            }

            // Filter chatItems to only keep valid items OR items that are very recent
            // (within last 2 seconds - these are hook-created placeholders for post-clear tools)
            let cutoffTime = Date().addingTimeInterval(-2)
            let previousCount = session.chatItems.count
            session.chatItems = session.chatItems.filter { item in
                validIds.contains(item.id) || item.timestamp > cutoffTime
            }

            // Also reset tool tracker
            session.toolTracker = ToolTracker()
            session.subagentState = SubagentState()

            session.needsClearReconciliation = false
            Self.logger.debug("Clear reconciliation: kept \(session.chatItems.count) of \(previousCount) items")
        }

        if payload.isIncremental {
            let existingIds = Set(session.chatItems.map { $0.id })

            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    if case .toolUse(let tool) = block {
                        if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                            if case .toolCall(let existingTool) = session.chatItems[idx].type {
                                session.chatItems[idx] = ChatHistoryItem(
                                    id: tool.id,
                                    type: .toolCall(ToolCallItem(
                                        name: tool.name,
                                        input: tool.input,
                                        status: existingTool.status,
                                        result: existingTool.result,
                                        structuredResult: existingTool.structuredResult,
                                        subagentTools: existingTool.subagentTools
                                    )),
                                    timestamp: message.timestamp
                                )
                            }
                            continue
                        }
                    }

                    let item = createChatItem(
                        from: block,
                        message: message,
                        blockIndex: blockIndex,
                        existingIds: existingIds,
                        completedTools: payload.completedToolIds,
                        toolResults: payload.toolResults,
                        structuredResults: payload.structuredResults,
                        toolTracker: &session.toolTracker
                    )

                    if let item = item {
                        session.chatItems.append(item)
                    }
                }
            }
        } else {
            let existingIds = Set(session.chatItems.map { $0.id })

            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    if case .toolUse(let tool) = block {
                        if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                            if case .toolCall(let existingTool) = session.chatItems[idx].type {
                                session.chatItems[idx] = ChatHistoryItem(
                                    id: tool.id,
                                    type: .toolCall(ToolCallItem(
                                        name: tool.name,
                                        input: tool.input,
                                        status: existingTool.status,
                                        result: existingTool.result,
                                        structuredResult: existingTool.structuredResult,
                                        subagentTools: existingTool.subagentTools
                                    )),
                                    timestamp: message.timestamp
                                )
                            }
                            continue
                        }
                    }

                    let item = createChatItem(
                        from: block,
                        message: message,
                        blockIndex: blockIndex,
                        existingIds: existingIds,
                        completedTools: payload.completedToolIds,
                        toolResults: payload.toolResults,
                        structuredResults: payload.structuredResults,
                        toolTracker: &session.toolTracker
                    )

                    if let item = item {
                        session.chatItems.append(item)
                    }
                }
            }

            session.chatItems.sort { $0.timestamp < $1.timestamp }
        }

        session.toolTracker.lastSyncTime = Date()

        await populateSubagentToolsFromAgentFiles(
            sessionId: payload.sessionId,
            session: &session,
            cwd: payload.cwd,
            structuredResults: payload.structuredResults
        )

        sessions[payload.sessionId] = session

        await emitToolCompletionEvents(
            sessionId: payload.sessionId,
            session: session,
            completedToolIds: payload.completedToolIds,
            toolResults: payload.toolResults,
            structuredResults: payload.structuredResults
        )
    }

    /// Populate subagent tools for Task/Agent tools using their agent JSONL files
    private func populateSubagentToolsFromAgentFiles(
        sessionId: String,
        session: inout SessionState,
        cwd: String,
        structuredResults: [String: ToolResultData]
    ) async {
        for i in 0..<session.chatItems.count {
            guard case .toolCall(var tool) = session.chatItems[i].type,
                  tool.isSubagentContainer,
                  let structuredResult = structuredResults[session.chatItems[i].id],
                  case .task(let taskResult) = structuredResult,
                  !taskResult.agentId.isEmpty else { continue }

            let taskToolId = session.chatItems[i].id

            // Store agentId → description mapping for AgentOutputTool display
            if let description = session.subagentState.activeTasks[taskToolId]?.description {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            } else if let description = tool.input["description"] {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            }

            let subagentProjectsDir = CLIConfig.forSource(session.source).jsonlProjectsDirRelative ?? ".claude/projects"
            let subagentToolInfos = await ConversationParser.shared.parseSubagentTools(
                sessionId: sessionId,
                agentId: taskResult.agentId,
                cwd: cwd,
                projectsDirRelative: subagentProjectsDir
            )

            guard !subagentToolInfos.isEmpty else { continue }

            tool.subagentTools = subagentToolInfos.map { info in
                SubagentToolCall(
                    id: info.id,
                    name: info.name,
                    input: info.input,
                    status: info.isCompleted ? .success : .running,
                    timestamp: parseTimestamp(info.timestamp) ?? Date()
                )
            }

            session.chatItems[i] = ChatHistoryItem(
                id: taskToolId,
                type: .toolCall(tool),
                timestamp: session.chatItems[i].timestamp
            )

            Self.logger.debug("Populated \(subagentToolInfos.count) subagent tools for Task \(taskToolId.prefix(12), privacy: .public) from agent \(taskResult.agentId.prefix(8), privacy: .public)")
        }
    }

    /// Emit toolCompleted events for tools that have results in JSONL but aren't marked complete yet
    private func emitToolCompletionEvents(
        sessionId: String,
        session: SessionState,
        completedToolIds: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData]
    ) async {
        for item in session.chatItems {
            guard case .toolCall(let tool) = item.type else { continue }

            // Only emit for tools that are running or waiting but have results in JSONL
            guard tool.status == .running || tool.status == .waitingForApproval else { continue }
            guard completedToolIds.contains(item.id) else { continue }

            let result = ToolCompletionResult.from(
                parserResult: toolResults[item.id],
                structuredResult: structuredResults[item.id]
            )

            // Process the completion event (this will update state and phase consistently)
            await process(.toolCompleted(sessionId: sessionId, toolUseId: item.id, result: result))
        }
    }

    /// Create chat item (checks existingIds to avoid duplicates)
    private func createChatItem(
        from block: MessageBlock,
        message: ChatMessage,
        blockIndex: Int,
        existingIds: Set<String>,
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        toolTracker: inout ToolTracker
    ) -> ChatHistoryItem? {
        switch block {
        case .text(let text):
            let itemId = "\(message.id)-text-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }

            if message.role == .user {
                return ChatHistoryItem(id: itemId, type: .user(text), timestamp: message.timestamp)
            } else {
                return ChatHistoryItem(id: itemId, type: .assistant(text), timestamp: message.timestamp)
            }

        case .toolUse(let tool):
            guard toolTracker.markSeen(tool.id) else { return nil }

            let isCompleted = completedTools.contains(tool.id)
            let status: ToolStatus = isCompleted ? .success : .running

            // Extract result text for completed tools
            var resultText: String? = nil
            if isCompleted, let parserResult = toolResults[tool.id] {
                if let stdout = parserResult.stdout, !stdout.isEmpty {
                    resultText = stdout
                } else if let stderr = parserResult.stderr, !stderr.isEmpty {
                    resultText = stderr
                } else if let content = parserResult.content, !content.isEmpty {
                    resultText = content
                }
            }

            return ChatHistoryItem(
                id: tool.id,
                type: .toolCall(ToolCallItem(
                    name: tool.name,
                    input: tool.input,
                    status: status,
                    result: resultText,
                    structuredResult: structuredResults[tool.id],
                    subagentTools: []
                )),
                timestamp: message.timestamp
            )

        case .thinking(let text):
            let itemId = "\(message.id)-thinking-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }

            // Skip empty thinking blocks — streaming can briefly produce empty
            // ones that would render as orphan grey dots.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            return ChatHistoryItem(id: itemId, type: .thinking(text), timestamp: message.timestamp)

        case .interrupted:
            let itemId = "\(message.id)-interrupted-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .interrupted, timestamp: message.timestamp)
        }
    }

    private func updateToolStatus(in session: inout SessionState, toolId: String, status: ToolStatus) {
        var found = false
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolId,
               case .toolCall(var tool) = session.chatItems[i].type {
                tool.status = status
                session.chatItems[i] = ChatHistoryItem(
                    id: toolId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                found = true
                break
            }
        }
        if !found {
            let count = session.chatItems.count
            Self.logger.warning("Tool \(toolId.prefix(16), privacy: .public) not found in chatItems (count: \(count))")
        }
    }

    // MARK: - Interrupt Processing

    private func processInterrupt(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Clear subagent state
        session.subagentState = SubagentState()

        // Mark running tools as interrupted
        for i in 0..<session.chatItems.count {
            if case .toolCall(var tool) = session.chatItems[i].type,
               tool.status == .running {
                tool.status = .interrupted
                session.chatItems[i] = ChatHistoryItem(
                    id: session.chatItems[i].id,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
            }
        }

        // Transition to idle
        if session.phase.canTransition(to: .idle) {
            session.phase = .idle
        }

        sessions[sessionId] = session
    }

    // MARK: - Clear Processing

    private func processClearDetected(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }

        Self.logger.info("Processing /clear for session \(sessionId.prefix(8), privacy: .public)")

        // Mark that a clear happened - the next fileUpdated will reconcile
        // by removing items that no longer exist in the parser's state
        session.needsClearReconciliation = true
        sessions[sessionId] = session

        Self.logger.info("/clear processed for session \(sessionId.prefix(8), privacy: .public) - marked for reconciliation")
    }

    // MARK: - Session End Processing

    private func processSessionEnd(sessionId: String) async {
        guard sessions.removeValue(forKey: sessionId) != nil else { return }
        cancelPendingSync(sessionId: sessionId)
        publishState()
    }

    // MARK: - History Loading

    private func loadHistoryFromFile(sessionId: String, cwd: String) async {
        let messages: [ChatMessage]
        let completedTools: Set<String>
        let toolResults: [String: ConversationParser.ToolResult]
        let structuredResults: [String: ToolResultData]
        let conversationInfo: ConversationInfo

        let emptyInfo = ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil,
                                         lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil)

        guard let session = sessions[sessionId] else {
            messages = []
            completedTools = []
            toolResults = [:]
            structuredResults = [:]
            conversationInfo = emptyInfo
            await process(.historyLoaded(
                sessionId: sessionId,
                messages: messages,
                completedTools: completedTools,
                toolResults: toolResults,
                structuredResults: structuredResults,
                conversationInfo: conversationInfo
            ))
            return
        }

        let kind = session.historyKind
        let config = CLIConfig.forSource(session.source)

        switch kind {
        case .codexRollout:
            // Codex: load from local rollout JSONL under ~/.codex/sessions/.
            // Remote Codex sessions do not have a local rollout file on this
            // machine; continue returning empty history for them (follow-up
            // work will add a remote helper mirroring the OpenCode path).
            if session.isRemote {
                messages = []
                completedTools = []
                toolResults = [:]
                structuredResults = [:]
                conversationInfo = emptyInfo
            } else if let codexId = session.codexRawSessionId {
                let result = await CodexRolloutParser.shared.parse(codexSessionId: codexId)
                messages = result.messages
                completedTools = result.completedToolIds
                toolResults = result.toolResults
                structuredResults = [:]
                conversationInfo = result.conversationInfo
            } else {
                messages = []
                completedTools = []
                toolResults = [:]
                structuredResults = [:]
                conversationInfo = emptyInfo
            }

        case .sqlite:
            // OpenCode: load from SQLite database (local) or remote helper (SSH).
            if let opencodeId = session.opencodeRawSessionId {
                let result: OpenCodeDBParser.ParseResult
                if session.isRemote, let hostId = session.remoteHostId {
                    result = await loadRemoteOpenCodeHistory(opencodeSessionId: opencodeId, hostId: hostId)
                } else {
                    result = await OpenCodeDBParser.shared.parse(opencodeSessionId: opencodeId)
                }
                messages = result.messages
                completedTools = result.completedToolIds
                toolResults = result.toolResults
                structuredResults = [:]
                conversationInfo = result.conversationInfo
            } else {
                messages = []
                completedTools = []
                toolResults = [:]
                structuredResults = [:]
                conversationInfo = emptyInfo
            }

        case .jsonl:
            // Claude Code and its forks: per-config projects directory.
            let projectsDir = config.jsonlProjectsDirRelative ?? ".claude/projects"
            messages = await ConversationParser.shared.parseFullConversation(
                sessionId: sessionId,
                cwd: cwd,
                projectsDirRelative: projectsDir
            )
            completedTools = await ConversationParser.shared.completedToolIds(for: sessionId)
            toolResults = await ConversationParser.shared.toolResults(for: sessionId)
            structuredResults = await ConversationParser.shared.structuredResults(for: sessionId)
            conversationInfo = await ConversationParser.shared.parse(
                sessionId: sessionId,
                cwd: cwd,
                projectsDirRelative: projectsDir
            )

        case .realtimeOnly:
            messages = []
            completedTools = []
            toolResults = [:]
            structuredResults = [:]
            conversationInfo = emptyInfo
        }

        // Process loaded history
        await process(.historyLoaded(
            sessionId: sessionId,
            messages: messages,
            completedTools: completedTools,
            toolResults: toolResults,
            structuredResults: structuredResults,
            conversationInfo: conversationInfo
        ))
    }

    /// Pull OpenCode conversation history from a remote host by invoking the
    /// installed `~/.vibehub/vibehub-state.py --opencode-db <sid>` helper over
    /// the existing SSH ControlMaster session. Falls back to an empty result
    /// on any failure (session id validation, SSH error, invalid JSON).
    private func loadRemoteOpenCodeHistory(opencodeSessionId: String, hostId: String) async -> OpenCodeDBParser.ParseResult {
        // Whitelist-validate the session id before it crosses the shell boundary.
        // OpenCode session ids are always nanoid-like (alphanumeric + `_`/`-`).
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard !opencodeSessionId.isEmpty,
              opencodeSessionId.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            await RemoteLog.shared.log(.warn, "opencode db query: invalid session id", hostId: hostId)
            return await OpenCodeDBParser.shared.parseRemoteJSON(opencodeSessionId: opencodeSessionId, jsonString: "")
        }

        let command = "python3 ~/.vibehub/vibehub-state.py --opencode-db '\(opencodeSessionId)'"
        let result = await RemoteManager.shared.exec(hostId: hostId, command: command)

        guard result.exitCode == 0, !result.output.isEmpty else {
            await RemoteLog.shared.log(
                .warn,
                "opencode db query failed: exit=\(result.exitCode) sid=\(opencodeSessionId.prefix(8))...",
                hostId: hostId
            )
            return await OpenCodeDBParser.shared.parseRemoteJSON(opencodeSessionId: opencodeSessionId, jsonString: "")
        }

        return await OpenCodeDBParser.shared.parseRemoteJSON(
            opencodeSessionId: opencodeSessionId,
            jsonString: result.output
        )
    }

    private func processHistoryLoaded(
        sessionId: String,
        messages: [ChatMessage],
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        conversationInfo: ConversationInfo
    ) async {
        guard var session = sessions[sessionId] else { return }

        // Update conversationInfo (summary, lastMessage, etc.)
        let summary = conversationInfo.summary ?? session.conversationInfo.summary
        let lastMessage = conversationInfo.lastMessage ?? session.conversationInfo.lastMessage
        let lastMessageRole = conversationInfo.lastMessageRole ?? session.conversationInfo.lastMessageRole
        let lastToolName = conversationInfo.lastToolName ?? session.conversationInfo.lastToolName
        let firstUserMessage = conversationInfo.firstUserMessage ?? session.conversationInfo.firstUserMessage
        let lastUserMessageDate = conversationInfo.lastUserMessageDate ?? session.conversationInfo.lastUserMessageDate

        session.conversationInfo = ConversationInfo(
            summary: summary,
            lastMessage: lastMessage,
            lastMessageRole: lastMessageRole,
            lastToolName: lastToolName,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: lastUserMessageDate
        )

        // For OpenCode and Codex sessions, clear real-time items before loading
        // authoritative history from disk. The on-disk record has the complete
        // conversation; real-time items (with "opencode-*"/"codex-*" synthetic
        // IDs) would otherwise duplicate content since IDs differ.
        if session.source == .opencode || session.source == .codex {
            session.chatItems.removeAll()
            session.toolTracker = ToolTracker()
        }

        // Convert messages to chat items
        let existingIds = Set(session.chatItems.map { $0.id })

        for message in messages {
            for (blockIndex, block) in message.content.enumerated() {
                let item = createChatItem(
                    from: block,
                    message: message,
                    blockIndex: blockIndex,
                    existingIds: existingIds,
                    completedTools: completedTools,
                    toolResults: toolResults,
                    structuredResults: structuredResults,
                    toolTracker: &session.toolTracker
                )

                if let item = item {
                    session.chatItems.append(item)
                }
            }
        }

        // Sort by timestamp
        session.chatItems.sort { $0.timestamp < $1.timestamp }

        sessions[sessionId] = session
    }

    // MARK: - File Sync Scheduling

    private func scheduleFileSync(sessionId: String, cwd: String) {
        // Cancel existing sync
        cancelPendingSync(sessionId: sessionId)

        // Look up the current session's projects dir so forks with non-.claude
        // JSONL storage read from the right path.
        let projectsDir = sessions[sessionId]
            .flatMap { CLIConfig.forSource($0.source).jsonlProjectsDirRelative }
            ?? ".claude/projects"

        // Schedule new debounced sync
        pendingSyncs[sessionId] = Task { [weak self, syncDebounceNs] in
            try? await Task.sleep(nanoseconds: syncDebounceNs)
            guard !Task.isCancelled else { return }

            // Parse incrementally - only get NEW messages since last call
            let result = await ConversationParser.shared.parseIncremental(
                sessionId: sessionId,
                cwd: cwd,
                projectsDirRelative: projectsDir
            )

            if result.clearDetected {
                await self?.process(.clearDetected(sessionId: sessionId))
            }

            guard !result.newMessages.isEmpty || result.clearDetected else {
                return
            }

            let payload = FileUpdatePayload(
                sessionId: sessionId,
                cwd: cwd,
                messages: result.newMessages,
                isIncremental: !result.clearDetected,
                completedToolIds: result.completedToolIds,
                toolResults: result.toolResults,
                structuredResults: result.structuredResults
            )

            await self?.process(.fileUpdated(payload))
        }
    }

    private func cancelPendingSync(sessionId: String) {
        pendingSyncs[sessionId]?.cancel()
        pendingSyncs.removeValue(forKey: sessionId)
    }

    // MARK: - Process Liveness Monitor

    private var processMonitorStarted = false

    /// Start periodic checking for dead session processes.
    /// Local sessions whose PID no longer exists are marked as ended.
    func startProcessMonitor() {
        guard !processMonitorStarted else { return }
        processMonitorStarted = true

        Task { [weak self] in
            while let self = self {
                try? await Task.sleep(for: .seconds(10))
                await self.pruneDeadSessions()
            }
        }
    }

    private func pruneDeadSessions() async {
        // Snapshot remote host connection status on MainActor
        let disconnectedHosts: Set<String> = await MainActor.run {
            let mgr = RemoteManager.shared
            var dead = Set<String>()
            for host in mgr.hosts {
                if let status = mgr.connectionStatus[host.id],
                   case .disconnected = status {
                    dead.insert(host.id)
                }
            }
            return dead
        }

        var changed = false
        var remoteSessionsToProbe: [(id: String, session: SessionState)] = []

        for (sessionId, session) in sessions {
            guard session.phase != .ended else { continue }

            var isDead = false

            if session.isRemote {
                // Remote session: check if SSH connection is down
                if let hostId = session.remoteHostId, disconnectedHosts.contains(hostId) {
                    isDead = true
                }
                // Remote session killed abnormally won't fire SessionEnd hook.
                // If idle for 30s, probe the remote process via SSH.
                if !isDead, !session.phase.isActive,
                   Date().timeIntervalSince(session.lastActivity) > 30 {
                    remoteSessionsToProbe.append((sessionId, session))
                }
            } else if let pid = session.pid {
                // Local session: check if process is still alive
                // kill(pid, 0) returns 0 if process exists, -1 if not
                isDead = kill(pid_t(pid), 0) != 0
            }

            if isDead {
                markSessionEnded(sessionId)
                changed = true
            }
        }

        // Probe remote sessions via SSH in parallel to check if Claude process is still running
        if !remoteSessionsToProbe.isEmpty {
            let deadSessionIds = await withTaskGroup(of: String?.self) { group in
                for (sessionId, session) in remoteSessionsToProbe {
                    guard let hostId = session.remoteHostId, let pid = session.pid else { continue }
                    group.addTask {
                        let (_, exitCode) = await RemoteManager.shared.exec(
                            hostId: hostId,
                            command: "kill -0 \(pid) 2>/dev/null"
                        )
                        return exitCode != 0 ? sessionId : nil
                    }
                }
                var ids: [String] = []
                for await id in group { if let id { ids.append(id) } }
                return ids
            }
            for sessionId in deadSessionIds {
                Self.logger.info("Remote session \(sessionId.prefix(8), privacy: .public) no longer alive")
                markSessionEnded(sessionId)
                changed = true
            }
        }

        if changed {
            publishState()
        }
    }

    private func markSessionEnded(_ sessionId: String) {
        guard var session = sessions[sessionId] else { return }
        session.phase = .ended
        sessions[sessionId] = session
        cancelPendingSync(sessionId: sessionId)

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            await self?.processSessionEnd(sessionId: sessionId)
        }
    }

    // MARK: - State Publishing

    private func publishState() {
        let sortedSessions = Array(sessions.values).sorted { $0.projectName < $1.projectName }
        sessionsSubject.send(sortedSessions)
    }

    // MARK: - Queries

    /// Find an existing OpenCode session with the given PID (for deduplication).
    /// Returns the session ID if found, nil otherwise.
    private func findExistingOpenCodeSession(forPid pid: Int, excluding sessionId: String) -> String? {
        for (id, session) in sessions where id != sessionId {
            if session.source == .opencode && session.pid == pid {
                return id
            }
        }
        return nil
    }

    /// Get a specific session
    func session(for sessionId: String) -> SessionState? {
        sessions[sessionId]
    }

    /// Check if there's an active permission for a session
    func hasActivePermission(sessionId: String) -> Bool {
        guard let session = sessions[sessionId] else { return false }
        if case .waitingForApproval = session.phase {
            return true
        }
        return false
    }

    /// Get all current sessions
    func allSessions() -> [SessionState] {
        Array(sessions.values)
    }
}
