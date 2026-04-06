//
//  HookEventTests.swift
//  VibeHubTests
//
//  Tests that verify HookEvent and HookResponse JSON serialisation/deserialisation
//  match the exact wire formats produced by:
//    • vibehub-state.py  (Claude Code hook – Python)
//    • vibehub-opencode.js (OpenCode plugin – JavaScript)
//
//  These tests do NOT require the CLIs to be installed.  Every payload below is
//  constructed from the actual field names each script sends over the Unix socket,
//  validated against the CodingKeys declared in HookSocketServer.swift.
//
//  If a CodingKey mapping is ever wrong (e.g. `_ppid` renamed to `ppid`) the
//  corresponding JSON test will catch it even though Swift-initialiser-based tests
//  would still pass.
//

@testable import VibeHub
import XCTest

// MARK: - Helpers

private let decoder = JSONDecoder()
private let encoder = JSONEncoder()

private func decode(_ json: String) throws -> HookEvent {
    try decoder.decode(HookEvent.self, from: Data(json.utf8))
}

// MARK: - Claude Code wire-format tests

final class ClaudeCodeHookEventJSONTests: XCTestCase {

    // MARK: UserPromptSubmit

    func testDecode_claudeCode_userPromptSubmit() throws {
        let json = """
        {
          "session_id": "abc-1234",
          "cwd": "/Users/alice/project",
          "event": "UserPromptSubmit",
          "pid": 9001,
          "tty": "/dev/ttys001",
          "status": "processing"
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.sessionId, "abc-1234")
        XCTAssertEqual(e.cwd, "/Users/alice/project")
        XCTAssertEqual(e.event, "UserPromptSubmit")
        XCTAssertEqual(e.pid, 9001)
        XCTAssertEqual(e.tty, "/dev/ttys001")
        XCTAssertEqual(e.status, "processing")
        XCTAssertNil(e.tool)
        XCTAssertNil(e.toolInput)
        XCTAssertNil(e.toolUseId)
        XCTAssertNil(e.sourcePid)
    }

    // MARK: PreToolUse

    func testDecode_claudeCode_preToolUse_bash() throws {
        let json = """
        {
          "session_id": "abc-1234",
          "cwd": "/Users/alice/project",
          "event": "PreToolUse",
          "pid": 9001,
          "tty": "/dev/ttys001",
          "status": "running_tool",
          "tool": "Bash",
          "tool_input": {"command": "ls -la /tmp"},
          "tool_use_id": "toolu_01ABCdef"
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.event, "PreToolUse")
        XCTAssertEqual(e.status, "running_tool")
        XCTAssertEqual(e.tool, "Bash")
        XCTAssertEqual(e.toolUseId, "toolu_01ABCdef")
        XCTAssertEqual(e.toolInput?["command"]?.value as? String, "ls -la /tmp")
    }

    func testDecode_claudeCode_preToolUse_read() throws {
        let json = """
        {
          "session_id": "abc-1234",
          "cwd": "/Users/alice/project",
          "event": "PreToolUse",
          "pid": 9001,
          "tty": "/dev/ttys001",
          "status": "running_tool",
          "tool": "Read",
          "tool_input": {"file_path": "/etc/hosts"},
          "tool_use_id": "toolu_readXYZ"
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.tool, "Read")
        XCTAssertEqual(e.toolInput?["file_path"]?.value as? String, "/etc/hosts")
    }

    func testDecode_claudeCode_preToolUse_write() throws {
        let json = """
        {
          "session_id": "abc-1234",
          "cwd": "/Users/alice/project",
          "event": "PreToolUse",
          "pid": 9001,
          "tty": null,
          "status": "running_tool",
          "tool": "Write",
          "tool_input": {"file_path": "/tmp/out.txt", "content": "hello"},
          "tool_use_id": "toolu_writeABC"
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.tool, "Write")
        XCTAssertNil(e.tty)
        XCTAssertEqual(e.toolInput?["file_path"]?.value as? String, "/tmp/out.txt")
    }

    func testDecode_claudeCode_preToolUse_task() throws {
        let json = """
        {
          "session_id": "abc-1234",
          "cwd": "/tmp",
          "event": "PreToolUse",
          "pid": 9001,
          "tty": "/dev/ttys001",
          "status": "running_tool",
          "tool": "Task",
          "tool_input": {"description": "Analyse the codebase"},
          "tool_use_id": "toolu_task1"
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.tool, "Task")
        XCTAssertEqual(e.toolInput?["description"]?.value as? String, "Analyse the codebase")
    }

    // MARK: PostToolUse

    func testDecode_claudeCode_postToolUse() throws {
        let json = """
        {
          "session_id": "abc-1234",
          "cwd": "/Users/alice/project",
          "event": "PostToolUse",
          "pid": 9001,
          "tty": "/dev/ttys001",
          "status": "processing",
          "tool": "Read",
          "tool_input": {"file_path": "/etc/hosts"},
          "tool_use_id": "toolu_readXYZ"
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.event, "PostToolUse")
        XCTAssertEqual(e.status, "processing")
        XCTAssertEqual(e.tool, "Read")
        XCTAssertEqual(e.toolUseId, "toolu_readXYZ")
    }

    // MARK: PermissionRequest

    func testDecode_claudeCode_permissionRequest_noToolUseId() throws {
        // PermissionRequest from Claude Code does NOT carry tool_use_id;
        // it is resolved from the PreToolUse cache on the Swift side.
        let json = """
        {
          "session_id": "abc-1234",
          "cwd": "/Users/alice/project",
          "event": "PermissionRequest",
          "pid": 9001,
          "tty": "/dev/ttys001",
          "status": "waiting_for_approval",
          "tool": "Bash",
          "tool_input": {"command": "rm -rf /important"}
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.event, "PermissionRequest")
        XCTAssertEqual(e.status, "waiting_for_approval")
        XCTAssertEqual(e.tool, "Bash")
        XCTAssertNil(e.toolUseId, "Claude Code PermissionRequest must not carry tool_use_id")
        XCTAssertTrue(e.expectsResponse)
    }

    // MARK: Notification – idle_prompt

    func testDecode_claudeCode_notification_idlePrompt() throws {
        let json = """
        {
          "session_id": "abc-1234",
          "cwd": "/Users/alice/project",
          "event": "Notification",
          "pid": 9001,
          "tty": "/dev/ttys001",
          "status": "waiting_for_input",
          "notification_type": "idle_prompt",
          "message": "Claude is waiting for your input"
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.event, "Notification")
        XCTAssertEqual(e.notificationType, "idle_prompt")
        XCTAssertEqual(e.message, "Claude is waiting for your input")
        // idle_prompt → determinePhase returns .idle regardless of status field
        XCTAssertEqual(e.determinePhase(), .idle)
    }

    // MARK: Notification – general

    func testDecode_claudeCode_notification_general() throws {
        let json = """
        {
          "session_id": "abc-1234",
          "cwd": "/Users/alice/project",
          "event": "Notification",
          "pid": 9001,
          "tty": "/dev/ttys001",
          "status": "notification",
          "notification_type": "idle",
          "message": "Task completed"
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.notificationType, "idle")
        XCTAssertEqual(e.message, "Task completed")
    }

    // MARK: Stop

    func testDecode_claudeCode_stop() throws {
        let json = """
        {
          "session_id": "abc-1234",
          "cwd": "/Users/alice/project",
          "event": "Stop",
          "pid": 9001,
          "tty": "/dev/ttys001",
          "status": "waiting_for_input"
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.event, "Stop")
        XCTAssertEqual(e.status, "waiting_for_input")
        XCTAssertEqual(e.determinePhase(), .waitingForInput)
    }

    // MARK: SubagentStop

    func testDecode_claudeCode_subagentStop() throws {
        let json = """
        {
          "session_id": "abc-1234",
          "cwd": "/Users/alice/project",
          "event": "SubagentStop",
          "pid": 9001,
          "tty": "/dev/ttys001",
          "status": "waiting_for_input"
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.event, "SubagentStop")
        XCTAssertEqual(e.determinePhase(), .waitingForInput)
    }

    // MARK: SessionStart

    func testDecode_claudeCode_sessionStart() throws {
        let json = """
        {
          "session_id": "abc-1234",
          "cwd": "/Users/alice/project",
          "event": "SessionStart",
          "pid": 9001,
          "tty": "/dev/ttys001",
          "status": "waiting_for_input"
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.event, "SessionStart")
        XCTAssertEqual(e.determinePhase(), .waitingForInput)
    }

    // MARK: SessionEnd

    func testDecode_claudeCode_sessionEnd() throws {
        let json = """
        {
          "session_id": "abc-1234",
          "cwd": "/Users/alice/project",
          "event": "SessionEnd",
          "pid": 9001,
          "tty": "/dev/ttys001",
          "status": "ended"
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.event, "SessionEnd")
        XCTAssertEqual(e.status, "ended")
    }

    // MARK: PreCompact

    func testDecode_claudeCode_preCompact() throws {
        let json = """
        {
          "session_id": "abc-1234",
          "cwd": "/Users/alice/project",
          "event": "PreCompact",
          "pid": 9001,
          "tty": "/dev/ttys001",
          "status": "compacting"
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.event, "PreCompact")
        XCTAssertEqual(e.determinePhase(), .compacting)
    }

    // MARK: Remote session metadata

    func testDecode_claudeCode_withRemoteHostId() throws {
        let json = """
        {
          "session_id": "abc-1234",
          "cwd": "/home/user/project",
          "event": "UserPromptSubmit",
          "pid": 42,
          "tty": null,
          "status": "processing",
          "_remote_host_id": "prod-server-1"
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.remoteHostId, "prod-server-1")
    }

    // MARK: Forward-compatibility: unknown fields are silently ignored

    func testDecode_claudeCode_unknownFieldsIgnored() throws {
        let json = """
        {
          "session_id": "abc-1234",
          "cwd": "/tmp",
          "event": "Stop",
          "pid": 1,
          "tty": null,
          "status": "waiting_for_input",
          "future_field_not_in_model": "should be ignored",
          "another_future_key": 99
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.event, "Stop")
    }
}

// MARK: - OpenCode wire-format tests

final class OpenCodeHookEventJSONTests: XCTestCase {

    // Baseline: all OpenCode payloads include these extra fields.
    // Tests verify they map to the correct Swift properties via CodingKeys.

    // MARK: SessionStart

    func testDecode_openCode_sessionStart() throws {
        let json = """
        {
          "session_id": "opencode-sess-abc",
          "_source": "opencode",
          "_ppid": 5678,
          "_env": {"TERM_PROGRAM": "iTerm.app"},
          "tty": "/dev/ttys002",
          "_server_port": 12345,
          "_server_hostname": "127.0.0.1",
          "cwd": "/Users/alice/project",
          "event": "SessionStart",
          "status": "waiting_for_input"
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.sessionId, "opencode-sess-abc")
        XCTAssertEqual(e.sourcePid, 5678)       // _ppid → sourcePid
        XCTAssertEqual(e.serverPort, 12345)     // _server_port → serverPort
        XCTAssertEqual(e.serverHostname, "127.0.0.1") // _server_hostname → serverHostname
        XCTAssertEqual(e.tty, "/dev/ttys002")
        XCTAssertEqual(e.event, "SessionStart")
        XCTAssertEqual(e.status, "waiting_for_input")
        // _source and _env have no corresponding model fields – they are silently dropped
        XCTAssertNil(e.pid, "OpenCode sends _ppid, not pid")
    }

    // MARK: SessionEnd

    func testDecode_openCode_sessionEnd() throws {
        let json = """
        {
          "session_id": "opencode-sess-abc",
          "_source": "opencode",
          "_ppid": 5678,
          "_env": {},
          "tty": "/dev/ttys002",
          "_server_port": 12345,
          "_server_hostname": "127.0.0.1",
          "event": "SessionEnd",
          "status": "ended",
          "cwd": "/Users/alice/project"
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.event, "SessionEnd")
        XCTAssertEqual(e.status, "ended")
        XCTAssertEqual(e.sourcePid, 5678)
    }

    // MARK: UserPromptSubmit

    func testDecode_openCode_userPromptSubmit() throws {
        let json = """
        {
          "session_id": "opencode-sess-abc",
          "_source": "opencode",
          "_ppid": 5678,
          "_env": {},
          "tty": "/dev/ttys002",
          "_server_port": 12345,
          "_server_hostname": "127.0.0.1",
          "event": "UserPromptSubmit",
          "status": "processing",
          "cwd": "/Users/alice/project",
          "prompt": "Explain this function"
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.event, "UserPromptSubmit")
        XCTAssertEqual(e.prompt, "Explain this function") // prompt → prompt
        XCTAssertEqual(e.sourcePid, 5678)
    }

    // MARK: AssistantMessage

    func testDecode_openCode_assistantMessage() throws {
        let json = """
        {
          "session_id": "opencode-sess-abc",
          "_source": "opencode",
          "_ppid": 5678,
          "_env": {},
          "tty": "/dev/ttys002",
          "_server_port": 12345,
          "_server_hostname": "127.0.0.1",
          "event": "AssistantMessage",
          "status": "processing",
          "cwd": "/Users/alice/project",
          "last_assistant_message": "The function reads a file."
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.event, "AssistantMessage")
        // last_assistant_message → lastAssistantMessage
        XCTAssertEqual(e.lastAssistantMessage, "The function reads a file.")
    }

    // MARK: Stop with last_assistant_message + codex_title

    func testDecode_openCode_stop_withTitleAndLastMessage() throws {
        let json = """
        {
          "session_id": "opencode-sess-abc",
          "_source": "opencode",
          "_ppid": 5678,
          "_env": {},
          "tty": "/dev/ttys002",
          "_server_port": 12345,
          "_server_hostname": "127.0.0.1",
          "event": "Stop",
          "status": "waiting_for_input",
          "cwd": "/Users/alice/project",
          "last_assistant_message": "Here is the analysis.",
          "codex_title": "Authentication Flow Analysis"
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.event, "Stop")
        XCTAssertEqual(e.lastAssistantMessage, "Here is the analysis.")
        XCTAssertEqual(e.codexTitle, "Authentication Flow Analysis")  // codex_title → codexTitle
        XCTAssertEqual(e.determinePhase(), .waitingForInput)
    }

    // MARK: PreToolUse

    func testDecode_openCode_preToolUse() throws {
        let json = """
        {
          "session_id": "opencode-sess-abc",
          "_source": "opencode",
          "_ppid": 5678,
          "_env": {},
          "tty": "/dev/ttys002",
          "_server_port": 12345,
          "_server_hostname": "127.0.0.1",
          "event": "PreToolUse",
          "status": "running_tool",
          "cwd": "/Users/alice/project",
          "tool": "Bash",
          "tool_input": {"command": "ls /tmp"},
          "tool_use_id": "toolu_opencode_1"
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.event, "PreToolUse")
        XCTAssertEqual(e.tool, "Bash")
        XCTAssertEqual(e.toolUseId, "toolu_opencode_1")
        XCTAssertEqual(e.toolInput?["command"]?.value as? String, "ls /tmp")
        XCTAssertTrue(e.isToolEvent)
    }

    // MARK: PostToolUse

    func testDecode_openCode_postToolUse() throws {
        let json = """
        {
          "session_id": "opencode-sess-abc",
          "_source": "opencode",
          "_ppid": 5678,
          "_env": {},
          "tty": "/dev/ttys002",
          "_server_port": 12345,
          "_server_hostname": "127.0.0.1",
          "event": "PostToolUse",
          "status": "processing",
          "cwd": "/Users/alice/project",
          "tool": "Bash",
          "tool_input": {"command": "ls /tmp"},
          "tool_use_id": "toolu_opencode_1"
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.event, "PostToolUse")
        XCTAssertTrue(e.isToolEvent)
    }

    // MARK: PermissionRequest – bash tool (from permission.asked)

    func testDecode_openCode_permissionRequest_bash() throws {
        // permission.asked generates a PreToolUse + PermissionRequest pair.
        // The PermissionRequest carries tool_use_id = the request ID.
        let json = """
        {
          "session_id": "opencode-sess-abc",
          "_source": "opencode",
          "_ppid": 5678,
          "_env": {},
          "tty": "/dev/ttys002",
          "_server_port": 12345,
          "_server_hostname": "127.0.0.1",
          "event": "PermissionRequest",
          "status": "waiting_for_approval",
          "cwd": "/Users/alice/project",
          "tool": "Bash",
          "tool_input": {"patterns": ["rm -rf /important"], "command": "rm -rf /important"},
          "tool_use_id": "req_abc123",
          "_opencode_request_id": "req_abc123"
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.event, "PermissionRequest")
        XCTAssertEqual(e.tool, "Bash")
        XCTAssertEqual(e.toolUseId, "req_abc123")
        XCTAssertTrue(e.expectsResponse)
        XCTAssertTrue(e.isToolEvent)
        // _opencode_request_id has no Swift field; it is silently ignored
    }

    // MARK: PermissionRequest – AskUserQuestion (from question.asked)

    func testDecode_openCode_permissionRequest_askUserQuestion() throws {
        let json = """
        {
          "session_id": "opencode-sess-abc",
          "_source": "opencode",
          "_ppid": 5678,
          "_env": {},
          "tty": "/dev/ttys002",
          "_server_port": 12345,
          "_server_hostname": "127.0.0.1",
          "event": "PermissionRequest",
          "status": "waiting_for_approval",
          "cwd": "/Users/alice/project",
          "tool": "AskUserQuestion",
          "tool_input": {
            "questions": [
              {
                "question": "Which API should I use?",
                "header": "Choose API",
                "options": [
                  {"label": "REST", "description": "HTTP REST"},
                  {"label": "GraphQL", "description": "GraphQL API"}
                ],
                "multiSelect": false
              }
            ]
          },
          "tool_use_id": "q_abc123"
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.event, "PermissionRequest")
        XCTAssertEqual(e.tool, "AskUserQuestion")
        XCTAssertEqual(e.toolUseId, "q_abc123")
        XCTAssertTrue(e.expectsResponse)
        // tool_input should decode questions array as nested AnyCodable
        XCTAssertNotNil(e.toolInput?["questions"])
    }

    // MARK: sourcePid mapping

    func testDecode_openCode_sourcePid_mappedFrom_ppid() throws {
        // The key insight: OpenCode sends "_ppid" but the model calls it "sourcePid".
        // Claude Code sends "pid" for the process PID; OpenCode sends "_ppid" for the
        // parent PID and does NOT include "pid".
        let json = """
        {
          "session_id": "opencode-x",
          "cwd": "/tmp",
          "event": "Stop",
          "status": "waiting_for_input",
          "_ppid": 99999,
          "_server_port": 8080,
          "_server_hostname": "localhost"
        }
        """
        let e = try decode(json)
        XCTAssertEqual(e.sourcePid, 99999)
        XCTAssertNil(e.pid, "OpenCode does not send the 'pid' field")
        XCTAssertEqual(e.serverPort, 8080)
        XCTAssertEqual(e.serverHostname, "localhost")
    }
}

// MARK: - HookResponse encoding tests

final class HookResponseEncodingTests: XCTestCase {

    private func encodeToDict(_ response: HookResponse) throws -> [String: Any] {
        let data = try encoder.encode(response)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    // MARK: Claude Code responses

    func testEncode_allow_claudeCode() throws {
        let response = HookResponse(decision: "allow", reason: nil, answers: nil)
        let dict = try encodeToDict(response)
        XCTAssertEqual(dict["decision"] as? String, "allow")
        // reason and answers absent from Claude Code allow response
    }

    func testEncode_deny_withReason_claudeCode() throws {
        let response = HookResponse(decision: "deny", reason: "Not allowed by user", answers: nil)
        let dict = try encodeToDict(response)
        XCTAssertEqual(dict["decision"] as? String, "deny")
        XCTAssertEqual(dict["reason"] as? String, "Not allowed by user")
    }

    func testEncode_ask_claudeCode() throws {
        // "ask" lets Claude Code show its own permission UI
        let response = HookResponse(decision: "ask", reason: nil, answers: nil)
        let dict = try encodeToDict(response)
        XCTAssertEqual(dict["decision"] as? String, "ask")
    }

    // MARK: OpenCode responses

    func testEncode_always_openCode() throws {
        // "always" maps to OpenCode's "always" permission reply
        let response = HookResponse(decision: "always", reason: nil, answers: nil)
        let dict = try encodeToDict(response)
        XCTAssertEqual(dict["decision"] as? String, "always")
    }

    func testEncode_allow_withAnswers_openCode_askUserQuestion() throws {
        // AskUserQuestion replies include selected option indices as [[String]]
        let answers: [[String]] = [["REST"], ["Option B"]]
        let response = HookResponse(decision: "allow", reason: nil, answers: answers)
        let dict = try encodeToDict(response)
        XCTAssertEqual(dict["decision"] as? String, "allow")
        let encoded = dict["answers"] as? [[String]]
        XCTAssertEqual(encoded, answers)
    }

    func testEncode_deny_openCode_withReason() throws {
        let response = HookResponse(decision: "deny", reason: "Risky operation", answers: nil)
        let dict = try encodeToDict(response)
        XCTAssertEqual(dict["decision"] as? String, "deny")
        XCTAssertEqual(dict["reason"] as? String, "Risky operation")
    }

    // MARK: Round-trip

    func testRoundTrip_hookResponse() throws {
        let original = HookResponse(decision: "allow", reason: "approved", answers: [["a", "b"]])
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(HookResponse.self, from: data)
        XCTAssertEqual(decoded.decision, original.decision)
        XCTAssertEqual(decoded.reason, original.reason)
        XCTAssertEqual(decoded.answers, original.answers)
    }
}

// MARK: - HookEvent property tests (determinePhase, isToolEvent, expectsResponse)

final class HookEventPropertyTests: XCTestCase {

    private func event(
        sessionId: String = "s",
        event: String,
        status: String,
        tool: String? = nil,
        toolUseId: String? = nil,
        notificationType: String? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp",
            event: event,
            status: status,
            pid: nil,
            sourcePid: nil,
            tty: nil,
            tool: tool,
            toolInput: nil,
            toolUseId: toolUseId,
            notificationType: notificationType,
            message: nil
        )
    }

    // MARK: determinePhase – all event types

    func testDeterminePhase_preToolUse_returnsProcessing() {
        let e = event(event: "PreToolUse", status: "running_tool")
        XCTAssertEqual(e.determinePhase(), .processing)
    }

    func testDeterminePhase_postToolUse_returnsProcessing() {
        let e = event(event: "PostToolUse", status: "processing")
        XCTAssertEqual(e.determinePhase(), .processing)
    }

    func testDeterminePhase_sessionStart_returnsWaitingForInput() {
        let e = event(event: "SessionStart", status: "waiting_for_input")
        XCTAssertEqual(e.determinePhase(), .waitingForInput)
    }

    func testDeterminePhase_sessionEnd_returnsIdle() {
        // "ended" status falls through to the default → idle
        let e = event(event: "SessionEnd", status: "ended")
        XCTAssertEqual(e.determinePhase(), .idle)
    }

    func testDeterminePhase_subagentStop_returnsWaitingForInput() {
        let e = event(event: "SubagentStop", status: "waiting_for_input")
        XCTAssertEqual(e.determinePhase(), .waitingForInput)
    }

    func testDeterminePhase_unknownStatus_returnsIdle() {
        let e = event(event: "UserPromptSubmit", status: "bogus_unknown_status")
        XCTAssertEqual(e.determinePhase(), .idle)
    }

    func testDeterminePhase_startingStatus_returnsProcessing() {
        // "starting" is treated as processing
        let e = event(event: "UserPromptSubmit", status: "starting")
        XCTAssertEqual(e.determinePhase(), .processing)
    }

    func testDeterminePhase_compactingStatus_returnsCompacting() {
        // Explicit status-driven compacting (PreCompact takes priority anyway,
        // but a payload with status=compacting should also work)
        let e = event(event: "PreCompact", status: "compacting")
        XCTAssertEqual(e.determinePhase(), .compacting)
    }

    func testDeterminePhase_notification_permissionPrompt_returnsIdle() {
        // The Python hook exits before sending permission_prompt notifications,
        // but if one arrives anyway the status "notification" → idle
        let e = event(event: "Notification", status: "notification", notificationType: "permission_prompt")
        XCTAssertEqual(e.determinePhase(), .idle)
    }

    // MARK: isToolEvent

    func testIsToolEvent_preToolUse() {
        XCTAssertTrue(event(event: "PreToolUse", status: "running_tool").isToolEvent)
    }

    func testIsToolEvent_postToolUse() {
        XCTAssertTrue(event(event: "PostToolUse", status: "processing").isToolEvent)
    }

    func testIsToolEvent_permissionRequest() {
        XCTAssertTrue(event(event: "PermissionRequest", status: "waiting_for_approval", tool: "Bash", toolUseId: "t").isToolEvent)
    }

    func testIsToolEvent_falseForNonToolEvents() {
        for name in ["UserPromptSubmit", "Stop", "SessionStart", "SessionEnd", "PreCompact", "Notification", "SubagentStop"] {
            XCTAssertFalse(event(event: name, status: "processing").isToolEvent, "\(name) should not be a tool event")
        }
    }

    // MARK: expectsResponse

    func testExpectsResponse_onlyForPermissionRequestWithWaitingStatus() {
        let yes = event(event: "PermissionRequest", status: "waiting_for_approval", tool: "Bash", toolUseId: "t")
        XCTAssertTrue(yes.expectsResponse)
    }

    func testExpectsResponse_falseForPermissionRequest_wrongStatus() {
        let no = event(event: "PermissionRequest", status: "processing")
        XCTAssertFalse(no.expectsResponse)
    }

    func testExpectsResponse_falseForAllOtherEvents() {
        for name in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionStart", "SessionEnd"] {
            let e = event(event: name, status: "waiting_for_approval")
            XCTAssertFalse(e.expectsResponse, "\(name) should not expect a response")
        }
    }

    // MARK: shouldSyncFile – OpenCode sessions never sync

    func testShouldSyncFile_falseForAllOpenCodeEvents() {
        let syncEvents = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionStart"]
        for name in syncEvents {
            let e = event(sessionId: "opencode-sess", event: name, status: "processing")
            XCTAssertFalse(e.shouldSyncFile, "OpenCode event \(name) must never trigger file sync")
        }
    }
}
