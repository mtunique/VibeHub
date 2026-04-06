//
//  ToolTrackerTests.swift
//  VibeHubTests
//
//  Tests for ToolTracker — markSeen, startTool, completeTool.
//

@testable import VibeHub
import XCTest

final class ToolTrackerTests: XCTestCase {

    // MARK: - markSeen

    func testMarkSeen_newId_returnsTrue() {
        var tracker = ToolTracker()
        XCTAssertTrue(tracker.markSeen("tool-1"))
    }

    func testMarkSeen_sameIdTwice_returnsFalseSecondTime() {
        var tracker = ToolTracker()
        XCTAssertTrue(tracker.markSeen("tool-1"))
        XCTAssertFalse(tracker.markSeen("tool-1"))
    }

    func testMarkSeen_differentIds_allReturnTrue() {
        var tracker = ToolTracker()
        XCTAssertTrue(tracker.markSeen("tool-1"))
        XCTAssertTrue(tracker.markSeen("tool-2"))
        XCTAssertTrue(tracker.markSeen("tool-3"))
    }

    // MARK: - hasSeen

    func testHasSeen_afterMarkSeen_returnsTrue() {
        var tracker = ToolTracker()
        _ = tracker.markSeen("tool-1")
        XCTAssertTrue(tracker.hasSeen("tool-1"))
    }

    func testHasSeen_withoutMarkSeen_returnsFalse() {
        let tracker = ToolTracker()
        XCTAssertFalse(tracker.hasSeen("unknown"))
    }

    func testHasSeen_afterMultipleInserts() {
        var tracker = ToolTracker()
        _ = tracker.markSeen("a")
        _ = tracker.markSeen("b")
        _ = tracker.markSeen("c")
        XCTAssertTrue(tracker.hasSeen("a"))
        XCTAssertTrue(tracker.hasSeen("b"))
        XCTAssertTrue(tracker.hasSeen("c"))
        XCTAssertFalse(tracker.hasSeen("d"))
    }

    // MARK: - startTool

    func testStartTool_addsToInProgress() {
        var tracker = ToolTracker()
        tracker.startTool(id: "t1", name: "Bash")
        XCTAssertNotNil(tracker.inProgress["t1"])
        XCTAssertEqual(tracker.inProgress["t1"]?.name, "Bash")
    }

    func testStartTool_marksIdAsSeen() {
        var tracker = ToolTracker()
        tracker.startTool(id: "t1", name: "Read")
        XCTAssertTrue(tracker.hasSeen("t1"))
    }

    func testStartTool_phaseIsRunning() {
        var tracker = ToolTracker()
        tracker.startTool(id: "t1", name: "Edit")
        XCTAssertEqual(tracker.inProgress["t1"]?.phase, .running)
    }

    func testStartTool_duplicateId_doesNotOverwrite() {
        var tracker = ToolTracker()
        tracker.startTool(id: "t1", name: "Bash")
        tracker.startTool(id: "t1", name: "Read")  // duplicate - should be ignored
        XCTAssertEqual(tracker.inProgress["t1"]?.name, "Bash")
    }

    // MARK: - completeTool

    func testCompleteTool_removesFromInProgress() {
        var tracker = ToolTracker()
        tracker.startTool(id: "t1", name: "Bash")
        XCTAssertNotNil(tracker.inProgress["t1"])
        tracker.completeTool(id: "t1", success: true)
        XCTAssertNil(tracker.inProgress["t1"])
    }

    func testCompleteTool_forUnknownId_isNoOp() {
        var tracker = ToolTracker()
        // Should not crash or add anything
        tracker.completeTool(id: "nonexistent", success: false)
        XCTAssertNil(tracker.inProgress["nonexistent"])
    }

    func testCompleteTool_preservesSeenIds() {
        var tracker = ToolTracker()
        tracker.startTool(id: "t1", name: "Bash")
        tracker.completeTool(id: "t1", success: true)
        // Tool is gone from inProgress but still marked as seen
        XCTAssertTrue(tracker.hasSeen("t1"))
    }

    // MARK: - Default State

    func testDefaultTracker_isEmpty() {
        let tracker = ToolTracker()
        XCTAssertTrue(tracker.inProgress.isEmpty)
        XCTAssertTrue(tracker.seenIds.isEmpty)
        XCTAssertEqual(tracker.lastSyncOffset, 0)
        XCTAssertNil(tracker.lastSyncTime)
    }

    // MARK: - Equatable

    func testTrackerEquality() {
        let date = Date()
        var t1 = ToolTracker(lastSyncTime: date)
        var t2 = ToolTracker(lastSyncTime: date)
        XCTAssertEqual(t1, t2)

        t1.startTool(id: "x", name: "Bash")
        XCTAssertNotEqual(t1, t2)

        t2.startTool(id: "x", name: "Bash")
        // Start times differ, so they won't be exactly equal - just check inProgress key exists
        XCTAssertNotNil(t1.inProgress["x"])
        XCTAssertNotNil(t2.inProgress["x"])
    }
}
