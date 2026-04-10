//
//  CodexRolloutParser.swift
//  VibeHub
//
//  Reads Codex CLI conversation history from its rollout JSONL files under
//  ~/.codex/sessions/YYYY/MM/DD/rollout-*-<session_id>.jsonl.
//
//  Format reference: Codex CLI source at codex-rs/protocol/src/protocol.rs
//  (RolloutLine + RolloutItem enum) and codex-rs/protocol/src/models.rs
//  (ResponseItem variants). See docs/engineering/ for the parser design.
//

import Foundation
import os.log

actor CodexRolloutParser {
    static let shared = CodexRolloutParser()

    nonisolated static let logger = Logger(subsystem: "com.vibehub", category: "CodexParser")

    // MARK: - Public API

    struct ParseResult {
        let messages: [ChatMessage]
        let completedToolIds: Set<String>
        let toolResults: [String: ConversationParser.ToolResult]
        let conversationInfo: ConversationInfo
    }

    private static let emptyResult = ParseResult(
        messages: [],
        completedToolIds: [],
        toolResults: [:],
        conversationInfo: ConversationInfo(
            summary: nil, lastMessage: nil, lastMessageRole: nil,
            lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
        )
    )

    /// Parse the rollout JSONL for the given Codex session id (the raw UUID
    /// without the `codex-` prefix).
    func parse(codexSessionId: String) -> ParseResult {
        guard let url = findRolloutFile(sessionId: codexSessionId) else {
            Self.logger.info("codex rollout file not found for \(codexSessionId, privacy: .public)")
            return Self.emptyResult
        }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            Self.logger.warning("codex rollout read failed: \(url.path, privacy: .public)")
            return Self.emptyResult
        }

        var chatMessages: [ChatMessage] = []
        var completedToolIds: Set<String> = []
        var toolResults: [String: ConversationParser.ToolResult] = [:]
        var firstUserText: String?
        var lastText: String?
        var lastUserDate: Date?

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFallback = ISO8601DateFormatter()
        isoFallback.formatOptions = [.withInternetDateTime]

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = root["type"] as? String
            else {
                continue
            }

            // Only response_item lines contribute to chat display (see plan).
            guard type == "response_item", let payload = root["payload"] as? [String: Any] else {
                continue
            }

            // Parse timestamp once per line.
            let timestamp: Date = {
                guard let ts = root["timestamp"] as? String else { return Date() }
                return isoFormatter.date(from: ts) ?? isoFallback.date(from: ts) ?? Date()
            }()

            handleResponseItem(
                payload: payload,
                timestamp: timestamp,
                chatMessages: &chatMessages,
                completedToolIds: &completedToolIds,
                toolResults: &toolResults,
                firstUserText: &firstUserText,
                lastText: &lastText,
                lastUserDate: &lastUserDate
            )
        }

        // Build ConversationInfo.
        // summary priority: session_index.jsonl thread_name → nil
        let threadName = loadThreadName(sessionId: codexSessionId)
        let summary: String? = {
            guard let t = threadName?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }()

        let firstUser = firstUserText.map { String($0.prefix(50)) }
        let lastMsg = lastText.map { Self.truncateInline($0, maxLength: 80) }
        let lastRole: String? = {
            guard let last = chatMessages.last else { return nil }
            return last.role == .user ? "user" : "assistant"
        }()

        let conversationInfo = ConversationInfo(
            summary: summary,
            lastMessage: lastMsg,
            lastMessageRole: lastRole,
            lastToolName: nil,
            firstUserMessage: firstUser,
            lastUserMessageDate: lastUserDate
        )

        return ParseResult(
            messages: chatMessages,
            completedToolIds: completedToolIds,
            toolResults: toolResults,
            conversationInfo: conversationInfo
        )
    }

    // MARK: - Response item dispatch

    private func handleResponseItem(
        payload: [String: Any],
        timestamp: Date,
        chatMessages: inout [ChatMessage],
        completedToolIds: inout Set<String>,
        toolResults: inout [String: ConversationParser.ToolResult],
        firstUserText: inout String?,
        lastText: inout String?,
        lastUserDate: inout Date?
    ) {
        guard let payloadType = payload["type"] as? String else { return }

        switch payloadType {
        case "message":
            handleMessage(
                payload: payload,
                timestamp: timestamp,
                chatMessages: &chatMessages,
                firstUserText: &firstUserText,
                lastText: &lastText,
                lastUserDate: &lastUserDate
            )

        case "reasoning":
            // Only surface plaintext reasoning. Encrypted_content is opaque —
            // we cannot decode it, so skip to avoid noise.
            guard let content = payload["content"] as? [[String: Any]] else { return }
            var buf = ""
            for item in content {
                let itemType = item["type"] as? String
                if itemType == "reasoning_text" || itemType == "text" {
                    if let t = item["text"] as? String, !t.isEmpty {
                        if !buf.isEmpty { buf += "\n\n" }
                        buf += t
                    }
                }
            }
            guard !buf.isEmpty else { return }
            let id = "codex-reasoning-\(chatMessages.count)-\(Int(timestamp.timeIntervalSince1970 * 1000))"
            chatMessages.append(ChatMessage(
                id: id,
                role: .assistant,
                timestamp: timestamp,
                content: [.thinking(buf)]
            ))

        case "function_call":
            guard let name = payload["name"] as? String,
                  let callId = payload["call_id"] as? String
            else { return }
            let argsString = payload["arguments"] as? String ?? ""
            let input = Self.parseJSONArgumentsToStringMap(argsString)
            let id = "codex-fc-\(callId)"
            chatMessages.append(ChatMessage(
                id: id,
                role: .assistant,
                timestamp: timestamp,
                content: [.toolUse(ToolUseBlock(id: callId, name: name, input: input))]
            ))

        case "function_call_output":
            guard let callId = payload["call_id"] as? String else { return }
            let output = Self.extractOutputText(payload["output"])
            toolResults[callId] = ConversationParser.ToolResult(
                content: output,
                stdout: output,
                stderr: nil,
                isError: false
            )
            completedToolIds.insert(callId)

        case "custom_tool_call":
            guard let name = payload["name"] as? String,
                  let callId = payload["call_id"] as? String
            else { return }
            // `input` is a raw string (e.g., apply_patch body), not JSON.
            let rawInput = payload["input"] as? String ?? ""
            let inputMap: [String: String] = rawInput.isEmpty ? [:] : ["input": rawInput]
            let id = "codex-ct-\(callId)"
            chatMessages.append(ChatMessage(
                id: id,
                role: .assistant,
                timestamp: timestamp,
                content: [.toolUse(ToolUseBlock(id: callId, name: name, input: inputMap))]
            ))

        case "custom_tool_call_output":
            guard let callId = payload["call_id"] as? String else { return }
            let output = Self.extractOutputText(payload["output"])
            toolResults[callId] = ConversationParser.ToolResult(
                content: output,
                stdout: output,
                stderr: nil,
                isError: false
            )
            completedToolIds.insert(callId)

        case "web_search_call":
            // Synthesize a tool call block named "WebSearch".
            let toolId = (payload["id"] as? String)
                ?? (payload["call_id"] as? String)
                ?? "codex-ws-\(chatMessages.count)"
            var inputMap: [String: String] = [:]
            if let action = payload["action"] as? [String: Any] {
                if let query = action["query"] as? String {
                    inputMap["query"] = query
                } else if let queries = action["queries"] as? [String], let first = queries.first {
                    inputMap["query"] = first
                } else if let url = action["url"] as? String {
                    inputMap["url"] = url
                }
            }
            let id = "codex-ws-\(toolId)"
            chatMessages.append(ChatMessage(
                id: id,
                role: .assistant,
                timestamp: timestamp,
                content: [.toolUse(ToolUseBlock(id: toolId, name: "WebSearch", input: inputMap))]
            ))
            // web_search_call is a completed action (Codex writes it after the search ran).
            if let status = payload["status"] as? String, status == "completed" {
                completedToolIds.insert(toolId)
                toolResults[toolId] = ConversationParser.ToolResult(
                    content: inputMap["query"] ?? inputMap["url"] ?? "",
                    stdout: inputMap["query"] ?? inputMap["url"] ?? "",
                    stderr: nil,
                    isError: false
                )
            }

        default:
            // local_shell_call, tool_search_call/output, image_generation_call,
            // ghost_snapshot, compaction — v1 skip.
            return
        }
    }

    private func handleMessage(
        payload: [String: Any],
        timestamp: Date,
        chatMessages: inout [ChatMessage],
        firstUserText: inout String?,
        lastText: inout String?,
        lastUserDate: inout Date?
    ) {
        guard let roleStr = payload["role"] as? String else { return }

        // Skip developer role (system prompt / permission instructions).
        if roleStr == "developer" { return }

        let role: ChatRole = roleStr == "user" ? .user : .assistant

        // Collect text content items. Accept both input_text and output_text.
        guard let contentArr = payload["content"] as? [[String: Any]] else { return }
        var texts: [String] = []
        for item in contentArr {
            let itemType = item["type"] as? String
            if itemType == "input_text" || itemType == "output_text" || itemType == "text" {
                if let t = item["text"] as? String, !t.isEmpty {
                    texts.append(t)
                }
            }
        }
        guard !texts.isEmpty else { return }

        // Filter synthetic user messages that only carry <environment_context>.
        if role == .user {
            let allSynthetic = texts.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("<environment_context") }
            if allSynthetic { return }
        }

        let blocks: [MessageBlock] = texts.map { .text($0) }
        let id = "codex-msg-\(chatMessages.count)-\(Int(timestamp.timeIntervalSince1970 * 1000))"
        chatMessages.append(ChatMessage(id: id, role: role, timestamp: timestamp, content: blocks))

        // Update info trackers.
        let joined = texts.joined(separator: "\n")
        lastText = joined
        if role == .user {
            if firstUserText == nil {
                firstUserText = joined
            }
            lastUserDate = timestamp
        }
    }

    // MARK: - File lookup

    private func findRolloutFile(sessionId: String) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        ]
        let suffix = "-\(sessionId).jsonl"

        for root in roots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                if name.hasPrefix("rollout-") && name.hasSuffix(suffix) {
                    return url
                }
            }
        }
        return nil
    }

    // MARK: - session_index.jsonl → thread_name

    private func loadThreadName(sessionId: String) -> String? {
        let fm = FileManager.default
        let path = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl")
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        var latest: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = rawLine.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  obj["id"] as? String == sessionId
            else { continue }
            if let name = obj["thread_name"] as? String {
                latest = name
            }
        }
        return latest
    }

    // MARK: - Helpers

    /// Parse the `arguments` JSON string of a `function_call` payload into
    /// a `[String: String]` map. Non-string scalar values are coerced to their
    /// string description so they remain visible in the UI (unlike the
    /// OpenCode parser which drops them).
    private static func parseJSONArgumentsToStringMap(_ argsString: String) -> [String: String] {
        guard let data = argsString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        var out: [String: String] = [:]
        for (key, value) in json {
            if let s = value as? String {
                out[key] = s
            } else if let n = value as? NSNumber {
                out[key] = n.stringValue
            } else if let b = value as? Bool {
                out[key] = b ? "true" : "false"
            } else if let nested = try? JSONSerialization.data(withJSONObject: value),
                      let s = String(data: nested, encoding: .utf8) {
                out[key] = s
            }
        }
        return out
    }

    /// Extract a display-friendly text from a `function_call_output.output`
    /// or `custom_tool_call_output.output` value. Codex writes two shapes:
    ///   1) plain text string
    ///   2) JSON-encoded `{"output": "...", "metadata": {...}}` string
    /// Try shape 2 first; fall back to raw text.
    private static func extractOutputText(_ output: Any?) -> String {
        guard let raw = output as? String else {
            // Rare shape: already structured content items.
            if let items = output as? [[String: Any]] {
                return items.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            return ""
        }
        // Try structured JSON string.
        if let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inner = obj["output"] as? String {
            return inner
        }
        return raw
    }

    private static func truncateInline(_ s: String, maxLength: Int) -> String {
        let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if cleaned.count > maxLength {
            return String(cleaned.prefix(maxLength - 3)) + "..."
        }
        return cleaned
    }
}
