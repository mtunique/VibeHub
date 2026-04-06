//
//  SessionStateTests.swift
//  VibeHubTests
//
//  Tests for SessionState initialization, derived properties, and display titles.
//

@testable import VibeHub
import XCTest

@MainActor
final class SessionStateTests: XCTestCase {

    // MARK: - Helpers

    private func makeState(
        sessionId: String = "test-session",
        cwd: String = "/Users/user/Projects/MyApp",
        projectName: String? = nil,
        pid: Int? = nil,
        phase: SessionPhase = .idle,
        summary: String? = nil,
        lastMessage: String? = nil,
        lastMessageRole: String? = nil,
        firstUserMessage: String? = nil
    ) -> SessionState {
        SessionState(
            sessionId: sessionId,
            cwd: cwd,
            projectName: projectName,
            pid: pid,
            phase: phase,
            conversationInfo: ConversationInfo(
                summary: summary,
                lastMessage: lastMessage,
                lastMessageRole: lastMessageRole,
                lastToolName: nil,
                firstUserMessage: firstUserMessage,
                lastUserMessageDate: nil
            )
        )
    }

    // MARK: - Initialization

    func testDefaultInitialization() {
        let state = SessionState(sessionId: "abc", cwd: "/tmp/project")
        XCTAssertEqual(state.sessionId, "abc")
        XCTAssertEqual(state.cwd, "/tmp/project")
        XCTAssertEqual(state.projectName, "project")
        XCTAssertNil(state.pid)
        XCTAssertNil(state.tty)
        XCTAssertFalse(state.isInTmux)
        XCTAssertNil(state.serverPort)
        XCTAssertNil(state.serverHostname)
        XCTAssertNil(state.remoteHostId)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertTrue(state.chatItems.isEmpty)
        XCTAssertFalse(state.needsClearReconciliation)
    }

    func testProjectNameDefaultsToLastPathComponent() {
        let state = SessionState(sessionId: "s", cwd: "/Users/bob/code/my-project")
        XCTAssertEqual(state.projectName, "my-project")
    }

    func testProjectNameCanBeOverridden() {
        let state = SessionState(sessionId: "s", cwd: "/Users/bob/code/my-project", projectName: "Custom Name")
        XCTAssertEqual(state.projectName, "Custom Name")
    }

    func testProjectNameForRootPath() {
        let state = SessionState(sessionId: "s", cwd: "/")
        XCTAssertEqual(state.projectName, "/")
    }

    // MARK: - Identifiable

    func testIdEqualsSessionId() {
        let state = SessionState(sessionId: "my-session", cwd: "/tmp")
        XCTAssertEqual(state.id, "my-session")
    }

    // MARK: - isRemote

    func testIsRemoteFalseByDefault() {
        let state = SessionState(sessionId: "s", cwd: "/tmp")
        XCTAssertFalse(state.isRemote)
    }

    func testIsRemoteTrueWhenRemoteHostIdSet() {
        let state = SessionState(sessionId: "s", cwd: "/tmp", remoteHostId: "host-1")
        XCTAssertTrue(state.isRemote)
    }

    // MARK: - opencodeRawSessionId

    func testOpencodeRawSessionId_nonOpencode() {
        let state = SessionState(sessionId: "claude-abc123", cwd: "/tmp")
        XCTAssertNil(state.opencodeRawSessionId)
    }

    func testOpencodeRawSessionId_opencode() {
        let state = SessionState(sessionId: "opencode-abc123", cwd: "/tmp")
        XCTAssertEqual(state.opencodeRawSessionId, "abc123")
    }

    // MARK: - stableId

    func testStableIdWithPid() {
        let state = SessionState(sessionId: "ses-1", cwd: "/tmp", pid: 12345)
        XCTAssertEqual(state.stableId, "12345-ses-1")
    }

    func testStableIdWithoutPid() {
        let state = SessionState(sessionId: "ses-1", cwd: "/tmp")
        XCTAssertEqual(state.stableId, "ses-1")
    }

    // MARK: - displayTitle

    func testDisplayTitleWithSummary() {
        let state = makeState(projectName: "MyApp", summary: "Fix bug in login")
        XCTAssertEqual(state.displayTitle, "MyApp - Fix bug in login")
    }

    func testDisplayTitleWithSummaryEqualToProjectName() {
        let state = makeState(projectName: "MyApp", summary: "MyApp")
        XCTAssertEqual(state.displayTitle, "MyApp")
    }

    func testDisplayTitleFallsBackToFirstUserMessage() {
        let state = makeState(projectName: "MyApp", firstUserMessage: "Hello world")
        XCTAssertEqual(state.displayTitle, "MyApp - Hello world")
    }

    func testDisplayTitleFallsBackToLastMessage() {
        let state = makeState(projectName: "MyApp", lastMessage: "Assistant reply")
        XCTAssertEqual(state.displayTitle, "MyApp - Assistant reply")
    }

    func testDisplayTitleFallsBackToProjectName() {
        let state = makeState(projectName: "MyApp")
        XCTAssertEqual(state.displayTitle, "MyApp")
    }

    func testDisplayTitlePrefersSummaryOverFirstUserMessage() {
        let state = makeState(projectName: "MyApp", summary: "Summary text", firstUserMessage: "User message")
        XCTAssertEqual(state.displayTitle, "MyApp - Summary text")
    }

    func testDisplayTitleTruncatesLongLastMessage() {
        let longMessage = String(repeating: "a", count: 100)
        let state = makeState(projectName: "P", lastMessage: longMessage)
        let title = state.displayTitle
        // "P - " + 57 chars + "..."
        XCTAssertTrue(title.hasSuffix("..."))
        XCTAssertLessThanOrEqual(title.count, "P - ".count + 60)
    }

    func testDisplayTitleStripsNewlinesInLastMessage() {
        let state = makeState(projectName: "P", lastMessage: "Line1\nLine2")
        XCTAssertEqual(state.displayTitle, "P - Line1 Line2")
    }

    func testDisplayTitleTrimsWhitespace() {
        let state = makeState(projectName: "P", summary: "  summary  ")
        XCTAssertEqual(state.displayTitle, "P - summary")
    }

    func testDisplayTitleSkipsBlankSummary() {
        let state = makeState(projectName: "P", summary: "   ", firstUserMessage: "User msg")
        XCTAssertEqual(state.displayTitle, "P - User msg")
    }

    // MARK: - compactDisplayTitle

    func testCompactDisplayTitleWithSummary() {
        let state = makeState(summary: "Short summary")
        XCTAssertEqual(state.compactDisplayTitle, "Short summary")
    }

    func testCompactDisplayTitleTruncatesAt44Chars() {
        let long = String(repeating: "x", count: 60)
        let state = makeState(summary: long)
        XCTAssertTrue(state.compactDisplayTitle.hasSuffix("..."))
        XCTAssertLessThanOrEqual(state.compactDisplayTitle.count, 44)
    }

    func testCompactDisplayTitleFallsBackToFirstUserMessage() {
        let state = makeState(firstUserMessage: "Tell me about this project")
        XCTAssertEqual(state.compactDisplayTitle, "Tell me about this project")
    }

    func testCompactDisplayTitleFallsBackToLastMessage() {
        let state = makeState(lastMessage: "Here is the answer")
        XCTAssertEqual(state.compactDisplayTitle, "Here is the answer")
    }

    func testCompactDisplayTitleFallsBackToProjectName() {
        let state = makeState(projectName: "SomeProject")
        XCTAssertEqual(state.compactDisplayTitle, "SomeProject")
    }

    // MARK: - windowHint

    func testWindowHintPrefersSummary() {
        let state = makeState(summary: "Summary", firstUserMessage: "User msg")
        XCTAssertEqual(state.windowHint, "Summary")
    }

    func testWindowHintFallsBackToFirstUserMessage() {
        let state = makeState(firstUserMessage: "User msg")
        XCTAssertEqual(state.windowHint, "User msg")
    }

    func testWindowHintFallsBackToProjectName() {
        let state = makeState(projectName: "MyProj")
        XCTAssertEqual(state.windowHint, "MyProj")
    }

    // MARK: - activePermission / pendingTool

    func testActivePermissionNilForNonApprovalPhase() {
        let state = makeState(phase: .processing)
        XCTAssertNil(state.activePermission)
    }

    func testActivePermissionReturnsContextForApprovalPhase() {
        let ctx = PermissionContext(toolUseId: "t-1", toolName: "Bash", toolInput: nil, receivedAt: Date())
        let state = makeState(phase: .waitingForApproval(ctx))
        XCTAssertNotNil(state.activePermission)
        XCTAssertEqual(state.activePermission?.toolName, "Bash")
    }

    func testPendingToolNameFromApprovalPhase() {
        let ctx = PermissionContext(toolUseId: "t-1", toolName: "Write", toolInput: nil, receivedAt: Date())
        let state = makeState(phase: .waitingForApproval(ctx))
        XCTAssertEqual(state.pendingToolName, "Write")
    }

    func testPendingToolIdFromApprovalPhase() {
        let ctx = PermissionContext(toolUseId: "tool-use-42", toolName: "Read", toolInput: nil, receivedAt: Date())
        let state = makeState(phase: .waitingForApproval(ctx))
        XCTAssertEqual(state.pendingToolId, "tool-use-42")
    }

    func testPendingToolNilForNonApprovalPhase() {
        let state = makeState(phase: .idle)
        XCTAssertNil(state.pendingToolName)
        XCTAssertNil(state.pendingToolId)
    }

    // MARK: - needsAttention / canInteract

    func testNeedsAttentionDelegatesToPhase() {
        let ctxState = makeState(phase: .waitingForApproval(
            PermissionContext(toolUseId: "t", toolName: "Bash", toolInput: nil, receivedAt: Date())
        ))
        XCTAssertTrue(ctxState.needsAttention)
        XCTAssertTrue(makeState(phase: .waitingForInput).needsAttention)
        XCTAssertFalse(makeState(phase: .idle).needsAttention)
        XCTAssertFalse(makeState(phase: .processing).needsAttention)
    }

    // MARK: - openCodeControlSocketPath

    func testOpenCodeControlSocketPath_nilForNonOpenCodeSession() {
        let state = SessionState(sessionId: "claude-abc123", cwd: "/tmp", pid: 999)
        XCTAssertNil(state.openCodeControlSocketPath)
    }

    func testOpenCodeControlSocketPath_nilWhenPidAbsent() {
        let state = SessionState(sessionId: "opencode-abc123", cwd: "/tmp")
        XCTAssertNil(state.openCodeControlSocketPath)
    }

    func testOpenCodeControlSocketPath_nonNilWhenOpenCodeAndPidSet() {
        let state = SessionState(sessionId: "opencode-abc123", cwd: "/tmp", pid: 42)
        XCTAssertNotNil(state.openCodeControlSocketPath)
    }

    func testOpenCodeControlSocketPath_containsPid() {
        let state = SessionState(sessionId: "opencode-abc123", cwd: "/tmp", pid: 12345)
        XCTAssertTrue(state.openCodeControlSocketPath?.contains("12345") == true)
    }

    func testOpenCodeControlSocketPath_endsWith_sockExtension() {
        let state = SessionState(sessionId: "opencode-abc123", cwd: "/tmp", pid: 1)
        XCTAssertTrue(state.openCodeControlSocketPath?.hasSuffix(".sock") == true)
    }

    func testOpenCodeControlSocketPath_differentPerPid() {
        let s1 = SessionState(sessionId: "opencode-x", cwd: "/tmp", pid: 100)
        let s2 = SessionState(sessionId: "opencode-x", cwd: "/tmp", pid: 200)
        XCTAssertNotEqual(s1.openCodeControlSocketPath, s2.openCodeControlSocketPath)
    }

    // MARK: - Equatable

    func testEqualStates() {
        let date = Date()
        let s1 = SessionState(sessionId: "s", cwd: "/tmp", lastActivity: date, createdAt: date)
        let s2 = SessionState(sessionId: "s", cwd: "/tmp", lastActivity: date, createdAt: date)
        XCTAssertEqual(s1, s2)
    }

    func testUnequalStatesOnSessionId() {
        let date = Date()
        let s1 = SessionState(sessionId: "s1", cwd: "/tmp", lastActivity: date, createdAt: date)
        let s2 = SessionState(sessionId: "s2", cwd: "/tmp", lastActivity: date, createdAt: date)
        XCTAssertNotEqual(s1, s2)
    }
}
