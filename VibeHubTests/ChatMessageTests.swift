//
//  ChatMessageTests.swift
//  VibeHubTests
//
//  Tests for ChatMessage, MessageBlock, ToolUseBlock, and ChatRole.
//

@testable import VibeHub
import XCTest

final class ChatMessageTests: XCTestCase {

    // MARK: - ChatRole

    func testChatRoleRawValues() {
        XCTAssertEqual(ChatRole.user.rawValue, "user")
        XCTAssertEqual(ChatRole.assistant.rawValue, "assistant")
        XCTAssertEqual(ChatRole.system.rawValue, "system")
    }

    func testChatRoleEquality() {
        XCTAssertEqual(ChatRole.user, ChatRole.user)
        XCTAssertNotEqual(ChatRole.user, ChatRole.assistant)
    }

    // MARK: - ChatMessage Equatable

    func testChatMessageEquality_sameId() {
        let date = Date()
        let m1 = ChatMessage(id: "m1", role: .user, timestamp: date, content: [.text("Hello")])
        let m2 = ChatMessage(id: "m1", role: .assistant, timestamp: date, content: [])
        // Equality is based only on id
        XCTAssertEqual(m1, m2)
    }

    func testChatMessageInequality_differentId() {
        let date = Date()
        let m1 = ChatMessage(id: "m1", role: .user, timestamp: date, content: [.text("Hello")])
        let m2 = ChatMessage(id: "m2", role: .user, timestamp: date, content: [.text("Hello")])
        XCTAssertNotEqual(m1, m2)
    }

    // MARK: - textContent

    func testTextContent_withSingleTextBlock() {
        let msg = ChatMessage(id: "1", role: .user, timestamp: Date(), content: [.text("Hello")])
        XCTAssertEqual(msg.textContent, "Hello")
    }

    func testTextContent_withMultipleTextBlocks_joinsWithNewline() {
        let msg = ChatMessage(id: "1", role: .assistant, timestamp: Date(), content: [
            .text("Line 1"),
            .text("Line 2")
        ])
        XCTAssertEqual(msg.textContent, "Line 1\nLine 2")
    }

    func testTextContent_withToolUseBlock_excludesNonText() {
        let tool = ToolUseBlock(id: "t1", name: "Bash", input: ["command": "ls"])
        let msg = ChatMessage(id: "1", role: .assistant, timestamp: Date(), content: [
            .text("Before tool"),
            .toolUse(tool),
            .text("After tool")
        ])
        XCTAssertEqual(msg.textContent, "Before tool\nAfter tool")
    }

    func testTextContent_withThinkingBlock_excludesThinking() {
        let msg = ChatMessage(id: "1", role: .assistant, timestamp: Date(), content: [
            .thinking("Hmm..."),
            .text("Result")
        ])
        XCTAssertEqual(msg.textContent, "Result")
    }

    func testTextContent_emptyContent_returnsEmptyString() {
        let msg = ChatMessage(id: "1", role: .user, timestamp: Date(), content: [])
        XCTAssertEqual(msg.textContent, "")
    }

    func testTextContent_onlyToolUse_returnsEmptyString() {
        let tool = ToolUseBlock(id: "t1", name: "Read", input: ["file_path": "/tmp/file"])
        let msg = ChatMessage(id: "1", role: .assistant, timestamp: Date(), content: [.toolUse(tool)])
        XCTAssertEqual(msg.textContent, "")
    }

    // MARK: - MessageBlock IDs

    func testMessageBlockId_text() {
        let block = MessageBlock.text("Hello world")
        XCTAssertTrue(block.id.hasPrefix("text-"))
    }

    func testMessageBlockId_toolUse() {
        let tool = ToolUseBlock(id: "my-tool-id", name: "Bash", input: [:])
        let block = MessageBlock.toolUse(tool)
        XCTAssertEqual(block.id, "tool-my-tool-id")
    }

    func testMessageBlockId_thinking() {
        let block = MessageBlock.thinking("deep thought")
        XCTAssertTrue(block.id.hasPrefix("thinking-"))
    }

    func testMessageBlockId_interrupted() {
        XCTAssertEqual(MessageBlock.interrupted.id, "interrupted")
    }

    // MARK: - MessageBlock typePrefix

    func testMessageBlockTypePrefix() {
        XCTAssertEqual(MessageBlock.text("x").typePrefix, "text")
        XCTAssertEqual(MessageBlock.toolUse(ToolUseBlock(id: "1", name: "B", input: [:])).typePrefix, "tool")
        XCTAssertEqual(MessageBlock.thinking("...").typePrefix, "thinking")
        XCTAssertEqual(MessageBlock.interrupted.typePrefix, "interrupted")
    }

    // MARK: - ToolUseBlock preview

    func testToolUsePreview_filePath() {
        let tool = ToolUseBlock(id: "1", name: "Read", input: ["file_path": "/Users/user/project/main.swift"])
        XCTAssertEqual(tool.preview, "/Users/user/project/main.swift")
    }

    func testToolUsePreview_path() {
        let tool = ToolUseBlock(id: "1", name: "Glob", input: ["path": "/tmp/dir"])
        XCTAssertEqual(tool.preview, "/tmp/dir")
    }

    func testToolUsePreview_filePathTakesPrecedenceOverPath() {
        let tool = ToolUseBlock(id: "1", name: "Edit", input: ["file_path": "/f.swift", "path": "/other"])
        XCTAssertEqual(tool.preview, "/f.swift")
    }

    func testToolUsePreview_command_firstLine() {
        let tool = ToolUseBlock(id: "1", name: "Bash", input: ["command": "echo hello\necho world"])
        XCTAssertEqual(tool.preview, "echo hello")
    }

    func testToolUsePreview_command_truncatesAt50Chars() {
        let longCmd = String(repeating: "x", count: 60)
        let tool = ToolUseBlock(id: "1", name: "Bash", input: ["command": longCmd])
        XCTAssertLessThanOrEqual(tool.preview.count, 50)
    }

    func testToolUsePreview_pattern() {
        let tool = ToolUseBlock(id: "1", name: "Grep", input: ["pattern": "func test"])
        XCTAssertEqual(tool.preview, "func test")
    }

    func testToolUsePreview_fallsBackToFirstValue() {
        let tool = ToolUseBlock(id: "1", name: "UnknownTool", input: ["someKey": "someValue"])
        XCTAssertEqual(tool.preview, "someValue")
    }

    func testToolUsePreview_emptyInput_returnsEmptyString() {
        let tool = ToolUseBlock(id: "1", name: "NoInput", input: [:])
        XCTAssertEqual(tool.preview, "")
    }

    // MARK: - ToolUseBlock Equatable

    func testToolUseBlockEquality() {
        let t1 = ToolUseBlock(id: "1", name: "Bash", input: ["command": "ls"])
        let t2 = ToolUseBlock(id: "1", name: "Bash", input: ["command": "ls"])
        XCTAssertEqual(t1, t2)
    }

    func testToolUseBlockInequality() {
        let t1 = ToolUseBlock(id: "1", name: "Bash", input: ["command": "ls"])
        let t2 = ToolUseBlock(id: "2", name: "Bash", input: ["command": "ls"])
        XCTAssertNotEqual(t1, t2)
    }
}
