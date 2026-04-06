//
//  SessionPhaseTests.swift
//  VibeHubTests
//
//  Tests for SessionPhase state machine transitions and properties.
//

@testable import VibeHub
import XCTest

@MainActor
final class SessionPhaseTests: XCTestCase {

    // MARK: - Helpers

    private func makePermissionContext(toolName: String = "Bash", toolUseId: String = "tool-1") -> PermissionContext {
        PermissionContext(
            toolUseId: toolUseId,
            toolName: toolName,
            toolInput: nil,
            receivedAt: Date()
        )
    }

    // MARK: - canTransition Tests

    func testIdleCanTransitionToProcessing() {
        XCTAssertTrue(SessionPhase.idle.canTransition(to: .processing))
    }

    func testIdleCanTransitionToWaitingForApproval() {
        XCTAssertTrue(SessionPhase.idle.canTransition(to: .waitingForApproval(makePermissionContext())))
    }

    func testIdleCanTransitionToCompacting() {
        XCTAssertTrue(SessionPhase.idle.canTransition(to: .compacting))
    }

    func testIdleCanTransitionToEnded() {
        XCTAssertTrue(SessionPhase.idle.canTransition(to: .ended))
    }

    func testIdleCannotTransitionToWaitingForInput() {
        XCTAssertFalse(SessionPhase.idle.canTransition(to: .waitingForInput))
    }

    func testProcessingCanTransitionToWaitingForInput() {
        XCTAssertTrue(SessionPhase.processing.canTransition(to: .waitingForInput))
    }

    func testProcessingCanTransitionToWaitingForApproval() {
        XCTAssertTrue(SessionPhase.processing.canTransition(to: .waitingForApproval(makePermissionContext())))
    }

    func testProcessingCanTransitionToCompacting() {
        XCTAssertTrue(SessionPhase.processing.canTransition(to: .compacting))
    }

    func testProcessingCanTransitionToIdle() {
        XCTAssertTrue(SessionPhase.processing.canTransition(to: .idle))
    }

    func testWaitingForInputCanTransitionToProcessing() {
        XCTAssertTrue(SessionPhase.waitingForInput.canTransition(to: .processing))
    }

    func testWaitingForInputCanTransitionToIdle() {
        XCTAssertTrue(SessionPhase.waitingForInput.canTransition(to: .idle))
    }

    func testWaitingForApprovalCanTransitionToProcessing() {
        let ctx = makePermissionContext()
        XCTAssertTrue(SessionPhase.waitingForApproval(ctx).canTransition(to: .processing))
    }

    func testWaitingForApprovalCanTransitionToIdle() {
        let ctx = makePermissionContext()
        XCTAssertTrue(SessionPhase.waitingForApproval(ctx).canTransition(to: .idle))
    }

    func testWaitingForApprovalCanTransitionToWaitingForInput() {
        let ctx = makePermissionContext()
        XCTAssertTrue(SessionPhase.waitingForApproval(ctx).canTransition(to: .waitingForInput))
    }

    func testWaitingForApprovalCanTransitionToAnotherApproval() {
        let ctx1 = makePermissionContext(toolUseId: "tool-1")
        let ctx2 = makePermissionContext(toolUseId: "tool-2")
        XCTAssertTrue(SessionPhase.waitingForApproval(ctx1).canTransition(to: .waitingForApproval(ctx2)))
    }

    func testCompactingCanTransitionToProcessing() {
        XCTAssertTrue(SessionPhase.compacting.canTransition(to: .processing))
    }

    func testCompactingCanTransitionToIdle() {
        XCTAssertTrue(SessionPhase.compacting.canTransition(to: .idle))
    }

    func testEndedIsTerminal() {
        XCTAssertFalse(SessionPhase.ended.canTransition(to: .idle))
        XCTAssertFalse(SessionPhase.ended.canTransition(to: .processing))
        XCTAssertFalse(SessionPhase.ended.canTransition(to: .waitingForInput))
        XCTAssertFalse(SessionPhase.ended.canTransition(to: .compacting))
        XCTAssertFalse(SessionPhase.ended.canTransition(to: .ended))
        XCTAssertFalse(SessionPhase.ended.canTransition(to: .waitingForApproval(makePermissionContext())))
    }

    func testSameStateTransition() {
        XCTAssertTrue(SessionPhase.idle.canTransition(to: .idle))
        XCTAssertTrue(SessionPhase.processing.canTransition(to: .processing))
        XCTAssertTrue(SessionPhase.waitingForInput.canTransition(to: .waitingForInput))
        XCTAssertTrue(SessionPhase.compacting.canTransition(to: .compacting))
    }

    // MARK: - transition(to:) Tests

    func testTransitionReturnsNewPhaseWhenValid() {
        let result = SessionPhase.idle.transition(to: .processing)
        XCTAssertEqual(result, .processing)
    }

    func testTransitionReturnsNilWhenInvalid() {
        let result = SessionPhase.ended.transition(to: .idle)
        XCTAssertNil(result)
    }

    func testTransitionFromIdleToWaitingForInput_returnsNil() {
        let result = SessionPhase.idle.transition(to: .waitingForInput)
        XCTAssertNil(result)
    }

    // MARK: - needsAttention Tests

    func testNeedsAttentionForWaitingForInput() {
        XCTAssertTrue(SessionPhase.waitingForInput.needsAttention)
    }

    func testNeedsAttentionForWaitingForApproval() {
        XCTAssertTrue(SessionPhase.waitingForApproval(makePermissionContext()).needsAttention)
    }

    func testNeedsAttentionFalseForOtherPhases() {
        XCTAssertFalse(SessionPhase.idle.needsAttention)
        XCTAssertFalse(SessionPhase.processing.needsAttention)
        XCTAssertFalse(SessionPhase.compacting.needsAttention)
        XCTAssertFalse(SessionPhase.ended.needsAttention)
    }

    // MARK: - isActive Tests

    func testIsActiveForProcessing() {
        XCTAssertTrue(SessionPhase.processing.isActive)
    }

    func testIsActiveForCompacting() {
        XCTAssertTrue(SessionPhase.compacting.isActive)
    }

    func testIsActiveFalseForOtherPhases() {
        XCTAssertFalse(SessionPhase.idle.isActive)
        XCTAssertFalse(SessionPhase.waitingForInput.isActive)
        XCTAssertFalse(SessionPhase.ended.isActive)
        XCTAssertFalse(SessionPhase.waitingForApproval(makePermissionContext()).isActive)
    }

    // MARK: - isWaitingForApproval Tests

    func testIsWaitingForApproval() {
        XCTAssertTrue(SessionPhase.waitingForApproval(makePermissionContext()).isWaitingForApproval)
        XCTAssertFalse(SessionPhase.idle.isWaitingForApproval)
        XCTAssertFalse(SessionPhase.processing.isWaitingForApproval)
    }

    // MARK: - approvalToolName Tests

    func testApprovalToolName() {
        let ctx = makePermissionContext(toolName: "Read")
        XCTAssertEqual(SessionPhase.waitingForApproval(ctx).approvalToolName, "Read")
    }

    func testApprovalToolNameNilForNonApprovalPhase() {
        XCTAssertNil(SessionPhase.idle.approvalToolName)
        XCTAssertNil(SessionPhase.processing.approvalToolName)
    }

    // MARK: - Equatable Tests

    func testEquatableIdenticalPhases() {
        XCTAssertEqual(SessionPhase.idle, SessionPhase.idle)
        XCTAssertEqual(SessionPhase.processing, SessionPhase.processing)
        XCTAssertEqual(SessionPhase.waitingForInput, SessionPhase.waitingForInput)
        XCTAssertEqual(SessionPhase.compacting, SessionPhase.compacting)
        XCTAssertEqual(SessionPhase.ended, SessionPhase.ended)
    }

    func testEquatableDifferentPhases() {
        XCTAssertNotEqual(SessionPhase.idle, SessionPhase.processing)
        XCTAssertNotEqual(SessionPhase.processing, SessionPhase.compacting)
    }

    func testEquatableWaitingForApprovalSameContext() {
        let date = Date()
        let ctx1 = PermissionContext(toolUseId: "t1", toolName: "Bash", toolInput: nil, receivedAt: date)
        let ctx2 = PermissionContext(toolUseId: "t1", toolName: "Bash", toolInput: nil, receivedAt: date)
        XCTAssertEqual(SessionPhase.waitingForApproval(ctx1), SessionPhase.waitingForApproval(ctx2))
    }

    func testEquatableWaitingForApprovalDifferentToolUseId() {
        let date = Date()
        let ctx1 = PermissionContext(toolUseId: "t1", toolName: "Bash", toolInput: nil, receivedAt: date)
        let ctx2 = PermissionContext(toolUseId: "t2", toolName: "Bash", toolInput: nil, receivedAt: date)
        XCTAssertNotEqual(SessionPhase.waitingForApproval(ctx1), SessionPhase.waitingForApproval(ctx2))
    }

    // MARK: - uiKey Tests

    func testUIKeys() {
        XCTAssertEqual(SessionPhase.idle.uiKey, "idle")
        XCTAssertEqual(SessionPhase.processing.uiKey, "processing")
        XCTAssertEqual(SessionPhase.waitingForInput.uiKey, "waitingForInput")
        XCTAssertEqual(SessionPhase.waitingForApproval(makePermissionContext()).uiKey, "waitingForApproval")
        XCTAssertEqual(SessionPhase.compacting.uiKey, "compacting")
        XCTAssertEqual(SessionPhase.ended.uiKey, "ended")
    }

    // MARK: - CustomStringConvertible Tests

    func testDescriptions() {
        XCTAssertEqual(SessionPhase.idle.description, "idle")
        XCTAssertEqual(SessionPhase.processing.description, "processing")
        XCTAssertEqual(SessionPhase.waitingForInput.description, "waitingForInput")
        XCTAssertEqual(SessionPhase.compacting.description, "compacting")
        XCTAssertEqual(SessionPhase.ended.description, "ended")
        let ctx = makePermissionContext(toolName: "Read")
        XCTAssertEqual(SessionPhase.waitingForApproval(ctx).description, "waitingForApproval(Read)")
    }
}
