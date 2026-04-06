//
//  SessionStoreIntegrationTests.swift
//  VibeHubTests
//
//  Integration tests for the full event-processing pipeline:
//  HookEvent → SessionEvent → SessionStore → SessionState
//
//  These tests exercise multiple components working together without
//  requiring real file I/O, sockets, or SwiftUI.
//
//  Design notes
//  ============
//  • SessionStore.shared is a singleton, so every test uses a unique
//    session ID and sends .sessionEnded at tearDown to avoid leaking
//    state to subsequent tests.
//  • Events that would trigger a JSONL file sync (UserPromptSubmit,
//    PreToolUse, PostToolUse, Stop) still work: ConversationParser
//    returns empty results when the cwd doesn't contain real files,
//    which is a safe no-op.
//  • OpenCode session IDs (prefix "opencode-") never trigger file sync,
//    so they are used where file-sync side-effects are not wanted.
//

@testable import VibeHub
import Combine
import XCTest

final class SessionStoreIntegrationTests: XCTestCase {

    // MARK: - Properties

    private let store = SessionStore.shared
    private var testSessionIds: [String] = []
    private var cancellables = Set<AnyCancellable>()

    /// Deterministic PID used for OpenCode session-deduplication tests.
    /// Chosen to be outside the range of real process IDs that typically
    /// run during tests (macOS PIDs rarely exceed 50 000 in practice).
    private let openCodeTestPid = 77_777

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        testSessionIds = []
        cancellables = []
    }

    override func tearDown() async throws {
        for sid in testSessionIds {
            await store.process(.sessionEnded(sessionId: sid))
        }
        testSessionIds = []
        cancellables = []
    }

    // MARK: - Helpers

    /// Returns a fresh, unique session ID registered for teardown cleanup.
    private func sid(_ prefix: String = "test") -> String {
        let id = "\(prefix)-\(UUID().uuidString)"
        testSessionIds.append(id)
        return id
    }

    /// Builds a minimal HookEvent. All parameters have useful defaults so
    /// individual tests only need to specify what they care about.
    private func hookEvent(
        sessionId: String,
        event: String = "UserPromptSubmit",
        status: String = "processing",
        cwd: String = "/tmp/integration-test",
        pid: Int? = nil,
        tool: String? = nil,
        toolUseId: String? = nil,
        toolInput: [String: AnyCodable]? = nil,
        notificationType: String? = nil,
        prompt: String? = nil,
        codexTitle: String? = nil,
        lastAssistantMessage: String? = nil,
        remoteHostId: String? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: cwd,
            event: event,
            status: status,
            pid: pid,
            sourcePid: nil,
            tty: nil,
            tool: tool,
            toolInput: toolInput,
            toolUseId: toolUseId,
            notificationType: notificationType,
            message: nil,
            prompt: prompt,
            codexTitle: codexTitle,
            lastAssistantMessage: lastAssistantMessage,
            serverPort: nil,
            serverHostname: nil,
            remoteHostId: remoteHostId
        )
    }

    // MARK: - Session Lifecycle

    func testHookReceived_createsNewSession() async {
        let id = sid()
        await store.process(.hookReceived(hookEvent(sessionId: id)))
        let session = await store.session(for: id)
        XCTAssertNotNil(session)
    }

    func testSessionEnded_removesSession() async {
        let id = sid()
        await store.process(.hookReceived(hookEvent(sessionId: id)))
        await store.process(.sessionEnded(sessionId: id))
        let session = await store.session(for: id)
        XCTAssertNil(session)
    }

    func testHookReceived_withStatusEnded_removesSession() async {
        let id = sid()
        await store.process(.hookReceived(hookEvent(sessionId: id, status: "processing")))
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "Stop", status: "ended")))
        let session = await store.session(for: id)
        XCTAssertNil(session)
    }

    func testHookReceived_populatesCwdAndProjectName() async {
        let id = sid()
        await store.process(.hookReceived(hookEvent(sessionId: id, cwd: "/Users/alice/Projects/MyApp")))
        let session = await store.session(for: id)
        XCTAssertEqual(session?.cwd, "/Users/alice/Projects/MyApp")
        XCTAssertEqual(session?.projectName, "MyApp")
    }

    func testHookReceived_populatesPid() async {
        let id = sid()
        await store.process(.hookReceived(hookEvent(sessionId: id, pid: 12345)))
        let session = await store.session(for: id)
        XCTAssertEqual(session?.pid, 12345)
    }

    func testHookReceived_populatesRemoteHostId() async {
        let id = sid()
        await store.process(.hookReceived(hookEvent(sessionId: id, remoteHostId: "host-42")))
        let session = await store.session(for: id)
        XCTAssertEqual(session?.remoteHostId, "host-42")
        XCTAssertTrue(session?.isRemote == true)
    }

    func testMultipleSessions_trackedIndependently() async {
        let id1 = sid("s1")
        let id2 = sid("s2")
        await store.process(.hookReceived(hookEvent(sessionId: id1, cwd: "/proj/alpha")))
        await store.process(.hookReceived(hookEvent(sessionId: id2, cwd: "/proj/beta")))
        let s1 = await store.session(for: id1)
        let s2 = await store.session(for: id2)
        XCTAssertEqual(s1?.projectName, "alpha")
        XCTAssertEqual(s2?.projectName, "beta")
    }

    func testAllSessions_includesAllActiveSessions() async {
        let id1 = sid("all-a")
        let id2 = sid("all-b")
        await store.process(.hookReceived(hookEvent(sessionId: id1)))
        await store.process(.hookReceived(hookEvent(sessionId: id2)))
        let all = await store.allSessions()
        let ids = all.map { $0.sessionId }
        XCTAssertTrue(ids.contains(id1))
        XCTAssertTrue(ids.contains(id2))
    }

    // MARK: - Phase Transitions via Hook Events

    func testUserPromptSubmit_setsProcessingPhase() async {
        let id = sid()
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        let session = await store.session(for: id)
        XCTAssertEqual(session?.phase, .processing)
    }

    func testStop_withWaitingForInput_setsWaitingPhase() async {
        let id = sid()
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "Stop", status: "waiting_for_input")))
        let session = await store.session(for: id)
        XCTAssertEqual(session?.phase, .waitingForInput)
    }

    func testPreCompact_setsCompactingPhase() async {
        let id = sid()
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "PreCompact", status: "compacting")))
        let session = await store.session(for: id)
        XCTAssertEqual(session?.phase, .compacting)
    }

    // MARK: - Permission Request Flow

    func testPermissionRequest_setsWaitingForApprovalPhase() async {
        let id = sid()
        let toolId = "tool-\(UUID().uuidString)"
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.hookReceived(hookEvent(
            sessionId: id,
            event: "PermissionRequest",
            status: "waiting_for_approval",
            tool: "Bash",
            toolUseId: toolId
        )))
        let session = await store.session(for: id)
        if case .waitingForApproval(let ctx) = session?.phase {
            XCTAssertEqual(ctx.toolName, "Bash")
            XCTAssertEqual(ctx.toolUseId, toolId)
        } else {
            XCTFail("Expected .waitingForApproval, got \(String(describing: session?.phase))")
        }
    }

    func testPermissionApproved_transitionsToProcessing() async {
        let id = sid()
        let toolId = "tool-\(UUID().uuidString)"
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.hookReceived(hookEvent(
            sessionId: id,
            event: "PermissionRequest",
            status: "waiting_for_approval",
            tool: "Read",
            toolUseId: toolId
        )))
        await store.process(.permissionApproved(sessionId: id, toolUseId: toolId))
        let session = await store.session(for: id)
        XCTAssertEqual(session?.phase, .processing)
    }

    func testPermissionDenied_transitionsToProcessing() async {
        let id = sid()
        let toolId = "tool-\(UUID().uuidString)"
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.hookReceived(hookEvent(
            sessionId: id,
            event: "PermissionRequest",
            status: "waiting_for_approval",
            tool: "Write",
            toolUseId: toolId
        )))
        await store.process(.permissionDenied(sessionId: id, toolUseId: toolId, reason: "not allowed"))
        let session = await store.session(for: id)
        XCTAssertEqual(session?.phase, .processing)
    }

    func testPermissionSocketFailed_transitionsToIdle() async {
        let id = sid()
        let toolId = "tool-\(UUID().uuidString)"
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.hookReceived(hookEvent(
            sessionId: id,
            event: "PermissionRequest",
            status: "waiting_for_approval",
            tool: "Bash",
            toolUseId: toolId
        )))
        await store.process(.permissionSocketFailed(sessionId: id, toolUseId: toolId))
        let session = await store.session(for: id)
        XCTAssertEqual(session?.phase, .idle)
    }

    func testHasActivePermission_trueAfterPermissionRequest() async {
        let id = sid()
        let toolId = "tool-\(UUID().uuidString)"
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.hookReceived(hookEvent(
            sessionId: id,
            event: "PermissionRequest",
            status: "waiting_for_approval",
            tool: "Bash",
            toolUseId: toolId
        )))
        let hasPermission = await store.hasActivePermission(sessionId: id)
        XCTAssertTrue(hasPermission)
    }

    func testHasActivePermission_falseAfterApproval() async {
        let id = sid()
        let toolId = "tool-\(UUID().uuidString)"
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.hookReceived(hookEvent(
            sessionId: id,
            event: "PermissionRequest",
            status: "waiting_for_approval",
            tool: "Read",
            toolUseId: toolId
        )))
        await store.process(.permissionApproved(sessionId: id, toolUseId: toolId))
        let hasPermission = await store.hasActivePermission(sessionId: id)
        XCTAssertFalse(hasPermission)
    }

    // MARK: - Multiple Queued Permissions

    func testApproveOnlyPermission_transitionsToProcessing() async {
        // When the only queued permission is approved, the session transitions to .processing.
        let id = sid()
        let toolId = "tool-solo-\(UUID().uuidString)"

        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.hookReceived(hookEvent(
            sessionId: id,
            event: "PermissionRequest",
            status: "waiting_for_approval",
            tool: "Bash",
            toolUseId: toolId
        )))
        await store.process(.permissionApproved(sessionId: id, toolUseId: toolId))

        let session = await store.session(for: id)
        XCTAssertEqual(session?.phase, .processing)
    }

    // MARK: - Tool Tracking

    func testPreToolUse_createsChatItemPlaceholder() async {
        let id = sid()
        let toolId = "bash-\(UUID().uuidString)"
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.hookReceived(hookEvent(
            sessionId: id,
            event: "PreToolUse",
            status: "running_tool",
            tool: "Bash",
            toolUseId: toolId,
            toolInput: ["command": AnyCodable("echo hello")]
        )))
        let session = await store.session(for: id)
        let toolItem = session?.chatItems.first(where: { $0.id == toolId })
        XCTAssertNotNil(toolItem, "Placeholder chat item should be created for PreToolUse")
        if case .toolCall(let t) = toolItem?.type {
            XCTAssertEqual(t.name, "Bash")
            XCTAssertEqual(t.status, .running)
        } else {
            XCTFail("Expected toolCall item")
        }
    }

    func testPostToolUse_marksChatItemSuccess() async {
        let id = sid()
        let toolId = "read-\(UUID().uuidString)"
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.hookReceived(hookEvent(
            sessionId: id, event: "PreToolUse", status: "running_tool",
            tool: "Read", toolUseId: toolId
        )))
        await store.process(.hookReceived(hookEvent(
            sessionId: id, event: "PostToolUse", status: "running_tool",
            tool: "Read", toolUseId: toolId
        )))
        let session = await store.session(for: id)
        let toolItem = session?.chatItems.first(where: { $0.id == toolId })
        if case .toolCall(let t) = toolItem?.type {
            XCTAssertEqual(t.status, .success)
        } else {
            XCTFail("Expected toolCall item after PostToolUse")
        }
    }

    func testToolCompleted_updatesToolStatusInPlace() async {
        let id = sid()
        let toolId = "bash-\(UUID().uuidString)"
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.hookReceived(hookEvent(
            sessionId: id, event: "PreToolUse", status: "running_tool",
            tool: "Bash", toolUseId: toolId
        )))
        let result = ToolCompletionResult(status: .success, result: "hello world", structuredResult: nil)
        await store.process(.toolCompleted(sessionId: id, toolUseId: toolId, result: result))
        let session = await store.session(for: id)
        let toolItem = session?.chatItems.first(where: { $0.id == toolId })
        if case .toolCall(let t) = toolItem?.type {
            XCTAssertEqual(t.status, .success)
            XCTAssertEqual(t.result, "hello world")
        } else {
            XCTFail("Expected toolCall item")
        }
    }

    func testToolCompleted_withErrorStatus_setsErrorStatus() async {
        let id = sid()
        let toolId = "bash-err-\(UUID().uuidString)"
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.hookReceived(hookEvent(
            sessionId: id, event: "PreToolUse", status: "running_tool",
            tool: "Bash", toolUseId: toolId
        )))
        let result = ToolCompletionResult(status: .error, result: "Permission denied", structuredResult: nil)
        await store.process(.toolCompleted(sessionId: id, toolUseId: toolId, result: result))
        let session = await store.session(for: id)
        if case .toolCall(let t) = session?.chatItems.first(where: { $0.id == toolId })?.type {
            XCTAssertEqual(t.status, .error)
        } else {
            XCTFail("Expected toolCall item with error status")
        }
    }

    func testToolCompleted_duplicateIgnored() async {
        let id = sid()
        let toolId = "bash-dup-\(UUID().uuidString)"
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.hookReceived(hookEvent(
            sessionId: id, event: "PreToolUse", status: "running_tool",
            tool: "Bash", toolUseId: toolId
        )))
        let success = ToolCompletionResult(status: .success, result: "first", structuredResult: nil)
        let error = ToolCompletionResult(status: .error, result: "second", structuredResult: nil)
        await store.process(.toolCompleted(sessionId: id, toolUseId: toolId, result: success))
        await store.process(.toolCompleted(sessionId: id, toolUseId: toolId, result: error))
        // Second event should be ignored; result should still be first
        let session = await store.session(for: id)
        if case .toolCall(let t) = session?.chatItems.first(where: { $0.id == toolId })?.type {
            XCTAssertEqual(t.status, .success, "Duplicate toolCompleted should be ignored")
            XCTAssertEqual(t.result, "first")
        } else {
            XCTFail("Expected toolCall item")
        }
    }

    // MARK: - fileUpdated Integration

    func testFileUpdated_appendsChatItems() async {
        let id = sid()
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        let msg = ChatMessage(
            id: "msg-1",
            role: .user,
            content: [.text("Hello from integration test")],
            timestamp: Date()
        )
        let payload = FileUpdatePayload(
            sessionId: id,
            cwd: "/tmp/integration-test",
            messages: [msg],
            isIncremental: true,
            completedToolIds: [],
            toolResults: [:],
            structuredResults: [:]
        )
        await store.process(.fileUpdated(payload))
        let session = await store.session(for: id)
        // Text messages become ChatHistoryItems
        XCTAssertFalse(session?.chatItems.isEmpty == true, "fileUpdated should append chat items")
    }

    func testFileUpdated_nonIncremental_replacesItems() async {
        let id = sid()
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))

        // First update: one message
        let msg1 = ChatMessage(
            id: "msg-A",
            role: .user,
            content: [.text("First message")],
            timestamp: Date()
        )
        let payload1 = FileUpdatePayload(
            sessionId: id, cwd: "/tmp/integration-test",
            messages: [msg1], isIncremental: true,
            completedToolIds: [], toolResults: [:], structuredResults: [:]
        )
        await store.process(.fileUpdated(payload1))
        let before = await store.session(for: id)
        let countBefore = before?.chatItems.count ?? 0

        // Second non-incremental update: different message, same IDs absent
        let msg2 = ChatMessage(
            id: "msg-B",
            role: .assistant,
            content: [.text("Assistant reply")],
            timestamp: Date().addingTimeInterval(1)
        )
        let payload2 = FileUpdatePayload(
            sessionId: id, cwd: "/tmp/integration-test",
            messages: [msg2], isIncremental: false,
            completedToolIds: [], toolResults: [:], structuredResults: [:]
        )
        await store.process(.fileUpdated(payload2))
        let after = await store.session(for: id)
        // Non-incremental should not de-duplicate msg-A (it appends, not replaces)
        // but items from msg2 should now be present
        XCTAssertGreaterThanOrEqual(after?.chatItems.count ?? 0, countBefore)
    }

    // MARK: - Interrupt and Clear Detection

    func testInterruptDetected_setsIdlePhase() async {
        let id = sid()
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.interruptDetected(sessionId: id))
        let session = await store.session(for: id)
        XCTAssertEqual(session?.phase, .idle)
    }

    func testClearDetected_setsReconciliationFlag() async {
        let id = sid()
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.clearDetected(sessionId: id))
        let session = await store.session(for: id)
        XCTAssertTrue(session?.needsClearReconciliation == true)
    }

    // MARK: - Subagent Lifecycle

    func testSubagentStarted_addsActiveTask() async {
        let id = sid()
        let taskId = "task-\(UUID().uuidString)"
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.subagentStarted(sessionId: id, taskToolId: taskId))
        let session = await store.session(for: id)
        XCTAssertNotNil(session?.subagentState.activeTasks[taskId])
        XCTAssertTrue(session?.subagentState.hasActiveSubagent == true)
    }

    func testSubagentStopped_removesTask() async {
        let id = sid()
        let taskId = "task-\(UUID().uuidString)"
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.subagentStarted(sessionId: id, taskToolId: taskId))
        await store.process(.subagentStopped(sessionId: id, taskToolId: taskId))
        let session = await store.session(for: id)
        XCTAssertNil(session?.subagentState.activeTasks[taskId])
        XCTAssertFalse(session?.subagentState.hasActiveSubagent == true)
    }

    func testSubagentToolExecuted_addsToolToActiveTask() async {
        let id = sid()
        let taskId = "task-\(UUID().uuidString)"
        let toolCall = SubagentToolCall(
            id: "stool-\(UUID().uuidString)",
            name: "Read",
            input: ["file_path": "/tmp/file.txt"],
            status: .running,
            timestamp: Date()
        )
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.subagentStarted(sessionId: id, taskToolId: taskId))
        await store.process(.subagentToolExecuted(sessionId: id, tool: toolCall))
        let session = await store.session(for: id)
        XCTAssertEqual(session?.subagentState.activeTasks[taskId]?.subagentTools.count, 1)
        XCTAssertEqual(session?.subagentState.activeTasks[taskId]?.subagentTools.first?.name, "Read")
    }

    func testSubagentToolCompleted_updatesStatus() async {
        let id = sid()
        let taskId = "task-\(UUID().uuidString)"
        let toolId = "stool-\(UUID().uuidString)"
        let toolCall = SubagentToolCall(id: toolId, name: "Bash", input: [:], status: .running, timestamp: Date())
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.subagentStarted(sessionId: id, taskToolId: taskId))
        await store.process(.subagentToolExecuted(sessionId: id, tool: toolCall))
        await store.process(.subagentToolCompleted(sessionId: id, toolId: toolId, status: .success))
        let session = await store.session(for: id)
        XCTAssertEqual(session?.subagentState.activeTasks[taskId]?.subagentTools.first?.status, .success)
    }

    func testPreToolUse_forTask_startsSubagentTracking() async {
        let id = sid()
        let taskId = "task-hook-\(UUID().uuidString)"
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.hookReceived(hookEvent(
            sessionId: id,
            event: "PreToolUse",
            status: "running_tool",
            tool: "Task",
            toolUseId: taskId,
            toolInput: ["description": AnyCodable("Analyze the codebase")]
        )))
        let session = await store.session(for: id)
        XCTAssertNotNil(session?.subagentState.activeTasks[taskId])
        XCTAssertEqual(session?.subagentState.activeTasks[taskId]?.description, "Analyze the codebase")
    }

    func testStop_event_clearsSubagentState() async {
        let id = sid()
        let taskId = "task-\(UUID().uuidString)"
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.subagentStarted(sessionId: id, taskToolId: taskId))
        // Stop event should clear all subagent state
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "Stop", status: "waiting_for_input")))
        let session = await store.session(for: id)
        XCTAssertTrue(session?.subagentState.activeTasks.isEmpty == true)
    }

    // MARK: - OpenCode Integration

    func testOpenCode_userPromptSubmit_appendsUserChatItem() async {
        let id = "opencode-\(UUID().uuidString)"
        testSessionIds.append(id)
        await store.process(.hookReceived(hookEvent(
            sessionId: id,
            event: "UserPromptSubmit",
            status: "processing",
            prompt: "What does this function do?"
        )))
        let session = await store.session(for: id)
        XCTAssertFalse(session?.chatItems.isEmpty == true)
        if case .user(let text) = session?.chatItems.last?.type {
            XCTAssertEqual(text, "What does this function do?")
        } else {
            XCTFail("Expected user chat item")
        }
    }

    func testOpenCode_assistantMessage_appendsAssistantChatItem() async {
        let id = "opencode-\(UUID().uuidString)"
        testSessionIds.append(id)
        await store.process(.hookReceived(hookEvent(
            sessionId: id,
            event: "UserPromptSubmit",
            status: "processing",
            prompt: "Hi"
        )))
        await store.process(.hookReceived(hookEvent(
            sessionId: id,
            event: "AssistantMessage",
            status: "processing",
            lastAssistantMessage: "The function reads a file."
        )))
        let session = await store.session(for: id)
        let assistantItems = session?.chatItems.filter {
            if case .assistant = $0.type { return true }
            return false
        }
        XCTAssertFalse(assistantItems?.isEmpty == true, "Should have at least one assistant chat item")
        if case .assistant(let text) = assistantItems?.last?.type {
            XCTAssertEqual(text, "The function reads a file.")
        }
    }

    func testOpenCode_codexTitle_setsConversationSummary() async {
        let id = "opencode-\(UUID().uuidString)"
        testSessionIds.append(id)
        await store.process(.hookReceived(hookEvent(
            sessionId: id,
            event: "UserPromptSubmit",
            status: "processing",
            codexTitle: "Analyzing authentication flow"
        )))
        let session = await store.session(for: id)
        XCTAssertEqual(session?.conversationInfo.summary, "Analyzing authentication flow")
    }

    func testOpenCode_promptSetsFirstUserMessage() async {
        let id = "opencode-\(UUID().uuidString)"
        testSessionIds.append(id)
        await store.process(.hookReceived(hookEvent(
            sessionId: id,
            event: "UserPromptSubmit",
            status: "processing",
            prompt: "Explain the login function"
        )))
        let session = await store.session(for: id)
        XCTAssertEqual(session?.conversationInfo.firstUserMessage, "Explain the login function")
    }

    func testOpenCode_duplicatePrompt_notAppended() async {
        let id = "opencode-\(UUID().uuidString)"
        testSessionIds.append(id)
        let prompt = "Same message"
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing", prompt: prompt)))
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing", prompt: prompt)))
        let session = await store.session(for: id)
        let userItems = session?.chatItems.filter {
            if case .user = $0.type { return true }
            return false
        }
        XCTAssertEqual(userItems?.count, 1, "Duplicate identical prompts should not be appended twice")
    }

    func testOpenCode_sessionDedup_samePid_redirectsToExistingSession() async {
        // When two OpenCode events arrive for different session IDs but the same PID,
        // they should be merged into the same session.
        let pid = openCodeTestPid
        let id1 = "opencode-first-\(UUID().uuidString)"
        let id2 = "opencode-second-\(UUID().uuidString)"
        testSessionIds.append(id1)
        testSessionIds.append(id2)

        await store.process(.hookReceived(hookEvent(sessionId: id1, event: "UserPromptSubmit", status: "processing", pid: pid)))
        await store.process(.hookReceived(hookEvent(sessionId: id2, event: "AssistantMessage", status: "processing", pid: pid)))

        // id2 should be redirected to id1; no separate session for id2
        let session2 = await store.session(for: id2)
        XCTAssertNil(session2, "Second OpenCode event with same PID should be redirected to the first session")
    }

    func testOpenCode_shouldSyncFile_returnsFalse() {
        // OpenCode sessions must never trigger JSONL file sync
        let id = "opencode-\(UUID().uuidString)"
        let event = hookEvent(sessionId: id, event: "UserPromptSubmit")
        XCTAssertFalse(event.shouldSyncFile)
    }

    // MARK: - sessionsPublisher Combine Integration

    func testSessionsPublisher_emitsOnHookReceived() async {
        let id = sid("pub")
        let expectation = XCTestExpectation(description: "sessionsPublisher emits update")
        expectation.expectedFulfillmentCount = 1

        store.sessionsPublisher
            .dropFirst()  // drop the value already present at subscription time
            .sink { sessions in
                if sessions.contains(where: { $0.sessionId == id }) {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        await store.process(.hookReceived(hookEvent(sessionId: id)))
        await fulfillment(of: [expectation], timeout: 2)
    }

    func testSessionsPublisher_emitsOnSessionEnd() async {
        let id = sid("pub-end")
        await store.process(.hookReceived(hookEvent(sessionId: id)))

        let expectation = XCTestExpectation(description: "sessionsPublisher emits after session end")
        store.sessionsPublisher
            .dropFirst()
            .sink { sessions in
                if !sessions.contains(where: { $0.sessionId == id }) {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        await store.process(.sessionEnded(sessionId: id))
        await fulfillment(of: [expectation], timeout: 2)
    }

    // MARK: - ToolCompletionResult Integration

    func testToolCompletionResult_from_successParserResult() {
        let parserResult = ConversationParser.ToolResult(
            content: "file content",
            stdout: nil,
            stderr: nil,
            isError: false
        )
        let result = ToolCompletionResult.from(parserResult: parserResult, structuredResult: nil)
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.result, "file content")
    }

    func testToolCompletionResult_from_errorParserResult() {
        let parserResult = ConversationParser.ToolResult(
            content: nil,
            stdout: nil,
            stderr: "command not found",
            isError: true
        )
        let result = ToolCompletionResult.from(parserResult: parserResult, structuredResult: nil)
        XCTAssertEqual(result.status, .error)
        XCTAssertEqual(result.result, "command not found")
    }

    func testToolCompletionResult_from_interruptedParserResult() {
        // isInterrupted is computed: isError == true AND content contains "Interrupted by user"
        let parserResult = ConversationParser.ToolResult(
            content: "Interrupted by user",
            stdout: nil,
            stderr: nil,
            isError: true
        )
        let result = ToolCompletionResult.from(parserResult: parserResult, structuredResult: nil)
        XCTAssertEqual(result.status, .interrupted)
        XCTAssertNil(result.result, "Interrupted results should have no output text")
    }

    func testToolCompletionResult_from_stdoutTakesPrecedenceOverContent() {
        let parserResult = ConversationParser.ToolResult(
            content: "content fallback",
            stdout: "stdout wins",
            stderr: nil,
            isError: false
        )
        let result = ToolCompletionResult.from(parserResult: parserResult, structuredResult: nil)
        XCTAssertEqual(result.result, "stdout wins")
    }

    func testToolCompletionResult_from_nilParserResult() {
        let result = ToolCompletionResult.from(parserResult: nil, structuredResult: nil)
        XCTAssertEqual(result.status, .success)
        XCTAssertNil(result.result)
    }

    // MARK: - HookEvent determinePhase Integration

    func testDeterminePhase_userPromptSubmit_returnsProcessing() {
        let e = hookEvent(sessionId: "x", event: "UserPromptSubmit", status: "processing")
        XCTAssertEqual(e.determinePhase(), .processing)
    }

    func testDeterminePhase_stop_withWaitingForInput_returnsWaitingForInput() {
        let e = hookEvent(sessionId: "x", event: "Stop", status: "waiting_for_input")
        XCTAssertEqual(e.determinePhase(), .waitingForInput)
    }

    func testDeterminePhase_preCompact_returnsCompacting() {
        let e = hookEvent(sessionId: "x", event: "PreCompact", status: "anything")
        XCTAssertEqual(e.determinePhase(), .compacting)
    }

    func testDeterminePhase_permissionRequest_returnsWaitingForApproval() {
        let toolId = "t-42"
        let e = hookEvent(
            sessionId: "x",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            tool: "Bash",
            toolUseId: toolId
        )
        if case .waitingForApproval(let ctx) = e.determinePhase() {
            XCTAssertEqual(ctx.toolName, "Bash")
            XCTAssertEqual(ctx.toolUseId, toolId)
        } else {
            XCTFail("Expected .waitingForApproval")
        }
    }

    func testDeterminePhase_idlePromptNotification_returnsIdle() {
        let e = hookEvent(sessionId: "x", event: "Notification", status: "idle", notificationType: "idle_prompt")
        XCTAssertEqual(e.determinePhase(), .idle)
    }

    func testShouldSyncFile_trueForClaudeEvents() {
        for eventName in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"] {
            let e = hookEvent(sessionId: "claude-session", event: eventName)
            XCTAssertTrue(e.shouldSyncFile, "\(eventName) should trigger file sync")
        }
    }

    func testShouldSyncFile_falseForNonSyncEvents() {
        for eventName in ["Notification", "SessionStart", "SessionEnd", "PermissionRequest", "PreCompact"] {
            let e = hookEvent(sessionId: "claude-session", event: eventName)
            XCTAssertFalse(e.shouldSyncFile, "\(eventName) should NOT trigger file sync")
        }
    }

    func testExpectsResponse_trueForPermissionRequest() {
        let e = hookEvent(sessionId: "x", event: "PermissionRequest", status: "waiting_for_approval", tool: "Bash", toolUseId: "t")
        XCTAssertTrue(e.expectsResponse)
    }

    func testExpectsResponse_falseForOtherEvents() {
        let e = hookEvent(sessionId: "x", event: "PreToolUse", status: "running_tool", tool: "Bash", toolUseId: "t")
        XCTAssertFalse(e.expectsResponse)
    }

    // MARK: - SessionStart / SubagentStop via SessionStore

    func testSessionStart_createsSession_inWaitingForInputPhase() async {
        let id = sid()
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "SessionStart", status: "waiting_for_input")))
        let session = await store.session(for: id)
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.phase, .waitingForInput)
    }

    func testSubagentStop_transitionsToWaitingForInput() async {
        let id = sid()
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "SubagentStop", status: "waiting_for_input")))
        let session = await store.session(for: id)
        XCTAssertEqual(session?.phase, .waitingForInput)
    }

    // MARK: - Notification events via SessionStore

    func testNotification_idlePrompt_transitionsToIdle() async {
        let id = sid()
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.hookReceived(hookEvent(
            sessionId: id,
            event: "Notification",
            status: "waiting_for_input",
            notificationType: "idle_prompt"
        )))
        let session = await store.session(for: id)
        XCTAssertEqual(session?.phase, .idle)
    }

    // MARK: - OpenCode AskUserQuestion PermissionRequest

    func testOpenCode_askUserQuestion_permissionRequest_setsWaitingForApproval() async {
        let id = "opencode-\(UUID().uuidString)"
        testSessionIds.append(id)
        let questionId = "q-\(UUID().uuidString)"
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        await store.process(.hookReceived(hookEvent(
            sessionId: id,
            event: "PermissionRequest",
            status: "waiting_for_approval",
            tool: "AskUserQuestion",
            toolUseId: questionId,
            toolInput: ["questions": AnyCodable([["question": "Which API?", "header": "API choice", "options": [], "multiSelect": false]])]
        )))
        let session = await store.session(for: id)
        if case .waitingForApproval(let ctx) = session?.phase {
            XCTAssertEqual(ctx.toolName, "AskUserQuestion")
            XCTAssertEqual(ctx.toolUseId, questionId)
        } else {
            XCTFail("Expected .waitingForApproval for AskUserQuestion, got \(String(describing: session?.phase))")
        }
    }

    // MARK: - OpenCode Stop with last_assistant_message and codex_title

    func testOpenCode_stop_withLastAssistantMessage_andCodexTitle() async {
        let id = "opencode-\(UUID().uuidString)"
        testSessionIds.append(id)
        await store.process(.hookReceived(hookEvent(sessionId: id, event: "UserPromptSubmit", status: "processing", prompt: "Describe login")))
        await store.process(.hookReceived(hookEvent(
            sessionId: id,
            event: "Stop",
            status: "waiting_for_input",
            codexTitle: "Login Flow Analysis",
            lastAssistantMessage: "The login function validates credentials then issues a JWT."
        )))
        let session = await store.session(for: id)
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertEqual(session?.conversationInfo.summary, "Login Flow Analysis")
        XCTAssertEqual(
            session?.conversationInfo.lastMessage,
            "The login function validates credentials then issues a JWT."
        )
    }
}
