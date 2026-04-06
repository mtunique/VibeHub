//
//  SubagentStateTests.swift
//  VibeHubTests
//
//  Tests for SubagentState — task lifecycle, tool tracking, agent ID mapping.
//

@testable import VibeHub
import XCTest

final class SubagentStateTests: XCTestCase {

    // MARK: - Default State

    func testDefaultState_hasNoActiveTasks() {
        let state = SubagentState()
        XCTAssertFalse(state.hasActiveSubagent)
        XCTAssertTrue(state.activeTasks.isEmpty)
        XCTAssertTrue(state.taskStack.isEmpty)
        XCTAssertTrue(state.agentDescriptions.isEmpty)
    }

    // MARK: - startTask

    func testStartTask_addsToActiveTasks() {
        var state = SubagentState()
        state.startTask(taskToolId: "task-1")
        XCTAssertNotNil(state.activeTasks["task-1"])
        XCTAssertEqual(state.activeTasks["task-1"]?.taskToolId, "task-1")
    }

    func testStartTask_setsDescription() {
        var state = SubagentState()
        state.startTask(taskToolId: "task-1", description: "Analyze files")
        XCTAssertEqual(state.activeTasks["task-1"]?.description, "Analyze files")
    }

    func testStartTask_noDescription_isNil() {
        var state = SubagentState()
        state.startTask(taskToolId: "task-1")
        XCTAssertNil(state.activeTasks["task-1"]?.description)
    }

    func testStartTask_setsHasActiveSubagent() {
        var state = SubagentState()
        state.startTask(taskToolId: "task-1")
        XCTAssertTrue(state.hasActiveSubagent)
    }

    func testStartTask_multipleTasksCoexist() {
        var state = SubagentState()
        state.startTask(taskToolId: "task-1")
        state.startTask(taskToolId: "task-2")
        XCTAssertEqual(state.activeTasks.count, 2)
    }

    // MARK: - stopTask

    func testStopTask_removesFromActiveTasks() {
        var state = SubagentState()
        state.startTask(taskToolId: "task-1")
        state.stopTask(taskToolId: "task-1")
        XCTAssertNil(state.activeTasks["task-1"])
        XCTAssertFalse(state.hasActiveSubagent)
    }

    func testStopTask_unknownId_isNoOp() {
        var state = SubagentState()
        state.startTask(taskToolId: "task-1")
        state.stopTask(taskToolId: "nonexistent")
        XCTAssertNotNil(state.activeTasks["task-1"])
    }

    func testStopTask_onlyRemovesTargetTask() {
        var state = SubagentState()
        state.startTask(taskToolId: "task-1")
        state.startTask(taskToolId: "task-2")
        state.stopTask(taskToolId: "task-1")
        XCTAssertNil(state.activeTasks["task-1"])
        XCTAssertNotNil(state.activeTasks["task-2"])
    }

    // MARK: - setAgentId

    func testSetAgentId_updatesAgentIdOnTask() {
        var state = SubagentState()
        state.startTask(taskToolId: "task-1", description: "My task")
        state.setAgentId("agent-abc", for: "task-1")
        XCTAssertEqual(state.activeTasks["task-1"]?.agentId, "agent-abc")
    }

    func testSetAgentId_recordsDescriptionInAgentDescriptions() {
        var state = SubagentState()
        state.startTask(taskToolId: "task-1", description: "Fix tests")
        state.setAgentId("agent-abc", for: "task-1")
        XCTAssertEqual(state.agentDescriptions["agent-abc"], "Fix tests")
    }

    func testSetAgentId_noDescription_doesNotPopulateAgentDescriptions() {
        var state = SubagentState()
        state.startTask(taskToolId: "task-1")
        state.setAgentId("agent-abc", for: "task-1")
        XCTAssertNil(state.agentDescriptions["agent-abc"])
    }

    func testSetAgentId_unknownTask_isNoOp() {
        var state = SubagentState()
        state.setAgentId("agent-abc", for: "nonexistent")
        XCTAssertTrue(state.activeTasks.isEmpty)
        XCTAssertTrue(state.agentDescriptions.isEmpty)
    }

    // MARK: - addSubagentTool (to specific task)

    func testAddSubagentToolToTask_appends() {
        var state = SubagentState()
        state.startTask(taskToolId: "task-1")
        let tool = makeSubagentToolCall(id: "stool-1")
        state.addSubagentToolToTask(tool, taskId: "task-1")
        XCTAssertEqual(state.activeTasks["task-1"]?.subagentTools.count, 1)
        XCTAssertEqual(state.activeTasks["task-1"]?.subagentTools.first?.id, "stool-1")
    }

    func testAddSubagentToolToTask_unknownTaskId_isNoOp() {
        var state = SubagentState()
        state.startTask(taskToolId: "task-1")
        let tool = makeSubagentToolCall(id: "stool-1")
        state.addSubagentToolToTask(tool, taskId: "nonexistent")
        XCTAssertTrue(state.activeTasks["task-1"]?.subagentTools.isEmpty == true)
    }

    // MARK: - addSubagentTool (to most recent task)

    func testAddSubagentTool_addedToMostRecentTask() {
        var state = SubagentState()
        state.startTask(taskToolId: "task-old")
        // Sleep briefly to ensure different start times
        Thread.sleep(forTimeInterval: 0.01)
        state.startTask(taskToolId: "task-new")
        let tool = makeSubagentToolCall(id: "stool-1")
        state.addSubagentTool(tool)
        // Should be added to the most recent task
        XCTAssertEqual(state.activeTasks["task-new"]?.subagentTools.count, 1)
        XCTAssertTrue(state.activeTasks["task-old"]?.subagentTools.isEmpty == true)
    }

    func testAddSubagentTool_noActiveTasks_isNoOp() {
        var state = SubagentState()
        let tool = makeSubagentToolCall(id: "stool-1")
        state.addSubagentTool(tool)
        XCTAssertTrue(state.activeTasks.isEmpty)
    }

    // MARK: - setSubagentTools

    func testSetSubagentTools_replacesAllTools() {
        var state = SubagentState()
        state.startTask(taskToolId: "task-1")
        state.addSubagentToolToTask(makeSubagentToolCall(id: "t1"), taskId: "task-1")
        state.addSubagentToolToTask(makeSubagentToolCall(id: "t2"), taskId: "task-1")
        let newTools = [makeSubagentToolCall(id: "t3")]
        state.setSubagentTools(newTools, for: "task-1")
        XCTAssertEqual(state.activeTasks["task-1"]?.subagentTools.count, 1)
        XCTAssertEqual(state.activeTasks["task-1"]?.subagentTools.first?.id, "t3")
    }

    // MARK: - updateSubagentToolStatus

    func testUpdateSubagentToolStatus_updatesCorrectTool() {
        var state = SubagentState()
        state.startTask(taskToolId: "task-1")
        state.addSubagentToolToTask(makeSubagentToolCall(id: "stool-1", status: .running), taskId: "task-1")
        state.updateSubagentToolStatus(toolId: "stool-1", status: .success)
        XCTAssertEqual(state.activeTasks["task-1"]?.subagentTools.first?.status, .success)
    }

    func testUpdateSubagentToolStatus_acrossMultipleTasks() {
        var state = SubagentState()
        state.startTask(taskToolId: "task-1")
        state.startTask(taskToolId: "task-2")
        state.addSubagentToolToTask(makeSubagentToolCall(id: "stool-1", status: .running), taskId: "task-1")
        state.addSubagentToolToTask(makeSubagentToolCall(id: "stool-2", status: .running), taskId: "task-2")
        state.updateSubagentToolStatus(toolId: "stool-2", status: .error)
        XCTAssertEqual(state.activeTasks["task-1"]?.subagentTools.first?.status, .running)
        XCTAssertEqual(state.activeTasks["task-2"]?.subagentTools.first?.status, .error)
    }

    func testUpdateSubagentToolStatus_unknownToolId_isNoOp() {
        var state = SubagentState()
        state.startTask(taskToolId: "task-1")
        state.addSubagentToolToTask(makeSubagentToolCall(id: "stool-1", status: .running), taskId: "task-1")
        state.updateSubagentToolStatus(toolId: "nonexistent", status: .success)
        XCTAssertEqual(state.activeTasks["task-1"]?.subagentTools.first?.status, .running)
    }

    // MARK: - Helpers

    private func makeSubagentToolCall(id: String, status: ToolStatus = .running) -> SubagentToolCall {
        SubagentToolCall(id: id, name: "Bash", input: [:], status: status, timestamp: Date())
    }
}
