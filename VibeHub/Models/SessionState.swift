//
//  SessionState.swift
//  VibeHub
//
//  Unified state model for a Claude session.
//  Consolidates all state that was previously spread across multiple components.
//

import Foundation

/// Complete state for a single Claude session
/// This is the single source of truth - all state reads and writes go through SessionStore
struct SessionState: Equatable, Identifiable, Sendable {
    // MARK: - Identity

    let sessionId: String
    let cwd: String
    let projectName: String

    // MARK: - Instance Metadata

    var pid: Int?
    var tty: String?
    var isInTmux: Bool
    /// OpenCode local server address (if available)
    var serverPort: Int?
    var serverHostname: String?
    /// cmux workspace / surface identifiers captured from the hook's
    /// `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID` environment variables.
    /// When non-nil, ChatView sends messages via the cmux CLI instead of
    /// TTY injection.
    var cmuxWorkspaceId: String?
    var cmuxSurfaceId: String?

    nonisolated var isInCmux: Bool { cmuxSurfaceId != nil || cmuxWorkspaceId != nil }

    /// If non-nil, this session is coming from a remote host.
    var remoteHostId: String?
    /// SSH client source port (from SSH_CLIENT env on remote), used for local tab matching
    var sshClientPort: String?

    nonisolated var isRemote: Bool { remoteHostId != nil }

    /// First-class CLI source. Written when the session is created from a
    /// `HookEvent`, based on `HookEvent.supportedCLI` (which in turn reads
    /// the `_source` field injected by `vibehub-state.py`). Defaults to
    /// `.claude` for sessions constructed before this field existed.
    var source: SupportedCLI = .claude

    nonisolated var opencodeRawSessionId: String? {
        guard let range = sessionId.range(of: "opencode-") else { return nil }
        return String(sessionId[range.upperBound...])
    }

    nonisolated var codexRawSessionId: String? {
        guard sessionId.hasPrefix("codex-") else { return nil }
        return String(sessionId.dropFirst("codex-".count))
    }

    /// Which history adapter SessionStore should use for this session.
    nonisolated var historyKind: HistoryKind {
        CLIConfig.forSource(source).capability.historyKind
    }

    nonisolated var openCodeControlSocketPath: String? {
        guard source == .opencode else { return nil }
        guard let pid else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibehub", isDirectory: true)
            .appendingPathComponent("ci-opencode-\(pid).sock")
            .path
    }

    // MARK: - State Machine

    /// Current phase in the session lifecycle
    var phase: SessionPhase

    // MARK: - Chat History

    /// All chat items for this session (replaces ChatHistoryManager.histories)
    var chatItems: [ChatHistoryItem]

    // MARK: - Tool Tracking

    /// Unified tool tracker (replaces 6+ dictionaries in ChatHistoryManager)
    var toolTracker: ToolTracker

    // MARK: - Subagent State

    /// State for Task tools and their nested subagent tools
    var subagentState: SubagentState

    // MARK: - Conversation Info (from JSONL parsing)

    var conversationInfo: ConversationInfo

    // MARK: - Clear Reconciliation

    /// When true, the next file update should reconcile chatItems with parser state
    /// This removes pre-/clear items that no longer exist in the JSONL
    var needsClearReconciliation: Bool

    // MARK: - Timestamps

    var lastActivity: Date
    var createdAt: Date

    // MARK: - Identifiable

    var id: String { sessionId }

    // MARK: - Initialization

    nonisolated init(
        sessionId: String,
        cwd: String,
        projectName: String? = nil,
        source: SupportedCLI? = nil,
        pid: Int? = nil,
        tty: String? = nil,
        isInTmux: Bool = false,
        serverPort: Int? = nil,
        serverHostname: String? = nil,
        remoteHostId: String? = nil,
        sshClientPort: String? = nil,
        cmuxWorkspaceId: String? = nil,
        cmuxSurfaceId: String? = nil,
        phase: SessionPhase = .idle,
        chatItems: [ChatHistoryItem] = [],
        toolTracker: ToolTracker = ToolTracker(),
        subagentState: SubagentState = SubagentState(),
        conversationInfo: ConversationInfo = ConversationInfo(
            summary: nil, lastMessage: nil, lastMessageRole: nil,
            lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
        ),
        needsClearReconciliation: Bool = false,
        lastActivity: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.projectName = projectName ?? URL(fileURLWithPath: cwd).lastPathComponent
        // Resolve source: explicit argument > legacy sessionId prefix > default .claude.
        self.source = source
            ?? SupportedCLI.from(sessionIdPrefix: sessionId)
            ?? .claude
        self.pid = pid
        self.tty = tty
        self.isInTmux = isInTmux
        self.serverPort = serverPort
        self.serverHostname = serverHostname
        self.remoteHostId = remoteHostId
        self.sshClientPort = sshClientPort
        self.cmuxWorkspaceId = cmuxWorkspaceId
        self.cmuxSurfaceId = cmuxSurfaceId
        self.phase = phase
        self.chatItems = chatItems
        self.toolTracker = toolTracker
        self.subagentState = subagentState
        self.conversationInfo = conversationInfo
        self.needsClearReconciliation = needsClearReconciliation
        self.lastActivity = lastActivity
        self.createdAt = createdAt
    }

    // MARK: - Derived Properties

    /// Whether this session needs user attention
    var needsAttention: Bool {
        phase.needsAttention
    }

    /// The active permission context, if any
    var activePermission: PermissionContext? {
        if case .waitingForApproval(let ctx) = phase {
            return ctx
        }
        return nil
    }

    // MARK: - UI Convenience Properties

    /// Stable identity for SwiftUI (combines PID and sessionId for animation stability)
    var stableId: String {
        if let pid = pid {
            return "\(pid)-\(sessionId)"
        }
        return sessionId
    }

    /// Display title: summary > first user message > project name
    var displayTitle: String {
        func cleaned(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? nil : t
        }

        func truncate(_ s: String, maxLength: Int) -> String {
            let oneLine = s.replacingOccurrences(of: "\n", with: " ")
            if oneLine.count > maxLength {
                return String(oneLine.prefix(maxLength - 3)) + "..."
            }
            return oneLine
        }

        let project = projectName

        if let summary = cleaned(conversationInfo.summary) {
            // Keep old behavior if summary already contains the project name.
            if summary == project { return summary }
            return "\(project) - \(summary)"
        }

        if let first = cleaned(conversationInfo.firstUserMessage) {
            if first == project { return first }
            return "\(project) - \(first)"
        }

        if let last = cleaned(conversationInfo.lastMessage) {
            let short = truncate(last, maxLength: 60)
            if short == project { return short }
            return "\(project) - \(short)"
        }

        return project
    }

    /// Short title used in compact UI (closed notch).
    /// Prefer meaning over uniqueness; keep it brief.
    var compactDisplayTitle: String {
        func cleaned(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? nil : t
        }

        func truncate(_ s: String, maxLength: Int) -> String {
            let oneLine = s.replacingOccurrences(of: "\n", with: " ")
            if oneLine.count > maxLength {
                return String(oneLine.prefix(maxLength - 3)) + "..."
            }
            return oneLine
        }

        if let summary = cleaned(conversationInfo.summary) {
            return truncate(summary, maxLength: 44)
        }
        if let first = cleaned(conversationInfo.firstUserMessage) {
            return truncate(first, maxLength: 44)
        }
        if let last = cleaned(conversationInfo.lastMessage) {
            return truncate(last, maxLength: 44)
        }
        return projectName
    }

    /// Best hint for matching window title
    var windowHint: String {
        // Prefer more context for window matching (eg OpenCode tabs).
        conversationInfo.summary ?? conversationInfo.firstUserMessage ?? projectName
    }

    /// Pending tool name if waiting for approval
    var pendingToolName: String? {
        activePermission?.toolName
    }

    /// Pending tool use ID
    var pendingToolId: String? {
        activePermission?.toolUseId
    }

    /// Formatted pending tool input for display
    var pendingToolInput: String? {
        activePermission?.formattedInput
    }

    /// Last message content
    var lastMessage: String? {
        conversationInfo.lastMessage
    }

    /// Last message role
    var lastMessageRole: String? {
        conversationInfo.lastMessageRole
    }

    /// Last tool name
    var lastToolName: String? {
        conversationInfo.lastToolName
    }

    /// Summary
    var summary: String? {
        conversationInfo.summary
    }

    /// First user message
    var firstUserMessage: String? {
        conversationInfo.firstUserMessage
    }

    /// Last user message date
    var lastUserMessageDate: Date? {
        conversationInfo.lastUserMessageDate
    }

    /// Whether the session can be interacted with
    var canInteract: Bool {
        phase.needsAttention
    }
}

// MARK: - Tool Tracker

/// Unified tool tracking - replaces multiple dictionaries in ChatHistoryManager
struct ToolTracker: Equatable, Sendable {
    /// Tools currently in progress, keyed by tool_use_id
    var inProgress: [String: ToolInProgress]

    /// All tool IDs we've seen (for deduplication)
    var seenIds: Set<String>

    /// Last JSONL file offset for incremental parsing
    var lastSyncOffset: UInt64

    /// Last sync timestamp
    var lastSyncTime: Date?

    nonisolated init(
        inProgress: [String: ToolInProgress] = [:],
        seenIds: Set<String> = [],
        lastSyncOffset: UInt64 = 0,
        lastSyncTime: Date? = nil
    ) {
        self.inProgress = inProgress
        self.seenIds = seenIds
        self.lastSyncOffset = lastSyncOffset
        self.lastSyncTime = lastSyncTime
    }

    /// Mark a tool ID as seen, returns true if it was new
    nonisolated mutating func markSeen(_ id: String) -> Bool {
        seenIds.insert(id).inserted
    }

    /// Check if a tool ID has been seen
    nonisolated func hasSeen(_ id: String) -> Bool {
        seenIds.contains(id)
    }

    /// Start tracking a tool
    nonisolated mutating func startTool(id: String, name: String) {
        guard markSeen(id) else { return }
        inProgress[id] = ToolInProgress(
            id: id,
            name: name,
            startTime: Date(),
            phase: .running
        )
    }

    /// Complete a tool
    nonisolated mutating func completeTool(id: String, success: Bool) {
        inProgress.removeValue(forKey: id)
    }
}

/// A tool currently in progress
struct ToolInProgress: Equatable, Sendable {
    let id: String
    let name: String
    let startTime: Date
    var phase: ToolInProgressPhase
}

/// Phase of a tool in progress
enum ToolInProgressPhase: Equatable, Sendable {
    case starting
    case running
    case pendingApproval
}

// MARK: - Subagent State

/// State for Task (subagent) tools
struct SubagentState: Equatable, Sendable {
    /// Active Task tools, keyed by task tool_use_id
    var activeTasks: [String: TaskContext]

    /// Ordered stack of active task IDs (most recent last) - used for proper tool assignment
    /// When multiple Tasks run in parallel, we use insertion order rather than timestamps
    var taskStack: [String]

    /// Mapping of agentId to Task description (for AgentOutputTool display)
    var agentDescriptions: [String: String]

    nonisolated init(activeTasks: [String: TaskContext] = [:], taskStack: [String] = [], agentDescriptions: [String: String] = [:]) {
        self.activeTasks = activeTasks
        self.taskStack = taskStack
        self.agentDescriptions = agentDescriptions
    }

    /// Whether there's an active subagent
    nonisolated var hasActiveSubagent: Bool {
        !activeTasks.isEmpty
    }

    /// Start tracking a Task tool
    nonisolated mutating func startTask(taskToolId: String, description: String? = nil) {
        activeTasks[taskToolId] = TaskContext(
            taskToolId: taskToolId,
            startTime: Date(),
            agentId: nil,
            description: description,
            subagentTools: []
        )
    }

    /// Stop tracking a Task tool
    nonisolated mutating func stopTask(taskToolId: String) {
        activeTasks.removeValue(forKey: taskToolId)
    }

    /// Set the agentId for a Task (called when agent file is discovered)
    nonisolated mutating func setAgentId(_ agentId: String, for taskToolId: String) {
        activeTasks[taskToolId]?.agentId = agentId
        if let description = activeTasks[taskToolId]?.description {
            agentDescriptions[agentId] = description
        }
    }

    /// Add a subagent tool to a specific Task by ID
    nonisolated mutating func addSubagentToolToTask(_ tool: SubagentToolCall, taskId: String) {
        activeTasks[taskId]?.subagentTools.append(tool)
    }

    /// Set all subagent tools for a specific Task (used when updating from agent file)
    nonisolated mutating func setSubagentTools(_ tools: [SubagentToolCall], for taskId: String) {
        activeTasks[taskId]?.subagentTools = tools
    }

    /// Add a subagent tool to the most recent active Task
    nonisolated mutating func addSubagentTool(_ tool: SubagentToolCall) {
        // Find most recent active task (for parallel Task support)
        guard let mostRecentTaskId = activeTasks.keys.max(by: {
            (activeTasks[$0]?.startTime ?? .distantPast) < (activeTasks[$1]?.startTime ?? .distantPast)
        }) else { return }

        activeTasks[mostRecentTaskId]?.subagentTools.append(tool)
    }

    /// Update the status of a subagent tool across all active Tasks
    nonisolated mutating func updateSubagentToolStatus(toolId: String, status: ToolStatus) {
        for taskId in activeTasks.keys {
            if let index = activeTasks[taskId]?.subagentTools.firstIndex(where: { $0.id == toolId }) {
                activeTasks[taskId]?.subagentTools[index].status = status
                return
            }
        }
    }
}

/// Context for an active Task tool
struct TaskContext: Equatable, Sendable {
    let taskToolId: String
    let startTime: Date
    var agentId: String?
    var description: String?
    var subagentTools: [SubagentToolCall]
}
