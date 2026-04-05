//
//  OpenCodeDBParser.swift
//  VibeHub
//
//  Reads OpenCode conversation history from its SQLite database
//  at ~/.local/share/opencode/opencode.db
//

import Foundation
import SQLite3

actor OpenCodeDBParser {
    static let shared = OpenCodeDBParser()

    private var dbPath: String {
        let home = NSHomeDirectory()
        return home + "/.local/share/opencode/opencode.db"
    }

    // MARK: - Public API

    struct ParseResult {
        let messages: [ChatMessage]
        let completedToolIds: Set<String>
        let toolResults: [String: ConversationParser.ToolResult]
        let conversationInfo: ConversationInfo
    }

    func parse(opencodeSessionId: String) -> ParseResult {
        guard let db = openDB() else {
            return ParseResult(
                messages: [],
                completedToolIds: [],
                toolResults: [:],
                conversationInfo: ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil, lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil)
            )
        }
        defer { sqlite3_close(db) }

        let sessionInfo = querySessionInfo(db: db, sessionId: opencodeSessionId)
        let rawMessages = queryMessages(db: db, sessionId: opencodeSessionId)
        let rawParts = queryParts(db: db, sessionId: opencodeSessionId)

        // Group parts by message_id
        var partsByMessage: [String: [(id: String, data: [String: Any], timeCreated: Int64)]] = [:]
        for part in rawParts {
            partsByMessage[part.messageId, default: []].append(
                (id: part.id, data: part.data, timeCreated: part.timeCreated)
            )
        }

        var chatMessages: [ChatMessage] = []
        var completedToolIds: Set<String> = []
        var toolResults: [String: ConversationParser.ToolResult] = [:]
        var firstUserText: String?
        var lastText: String?

        for msg in rawMessages {
            let role: ChatRole = msg.role == "user" ? .user : .assistant
            let timestamp = Date(timeIntervalSince1970: Double(msg.timeCreated) / 1000.0)
            var blocks: [MessageBlock] = []

            let parts = partsByMessage[msg.id] ?? []
            // Sort parts by time_created
            let sortedParts = parts.sorted { $0.timeCreated < $1.timeCreated }

            for part in sortedParts {
                guard let partType = part.data["type"] as? String else { continue }

                switch partType {
                case "text":
                    guard let text = part.data["text"] as? String, !text.isEmpty else { continue }
                    blocks.append(.text(text))
                    lastText = text
                    if role == .user && firstUserText == nil {
                        firstUserText = text
                    }

                case "tool":
                    guard let toolName = part.data["tool"] as? String else { continue }
                    let callID = part.data["callID"] as? String ?? part.id
                    let state = part.data["state"] as? [String: Any]
                    let status = state?["status"] as? String
                    let input = state?["input"] as? [String: Any] ?? [:]
                    let output = state?["output"] as? String

                    // Convert input to [String: String]
                    var stringInput: [String: String] = [:]
                    for (key, value) in input {
                        if let s = value as? String {
                            stringInput[key] = s
                        }
                    }

                    // Capitalize tool name to match Claude Code conventions
                    let normalizedName = titleCase(toolName)

                    blocks.append(.toolUse(ToolUseBlock(
                        id: callID,
                        name: normalizedName,
                        input: stringInput
                    )))

                    if status == "completed" || status == "error" {
                        completedToolIds.insert(callID)
                        toolResults[callID] = ConversationParser.ToolResult(
                            content: output,
                            stdout: output,
                            stderr: nil,
                            isError: status == "error"
                        )
                    }

                case "reasoning":
                    guard let text = part.data["text"] as? String, !text.isEmpty else { continue }
                    blocks.append(.thinking(text))

                default:
                    // step-start, step-finish, subtask, patch, compaction — skip
                    continue
                }
            }

            guard !blocks.isEmpty else { continue }

            chatMessages.append(ChatMessage(
                id: msg.id,
                role: role,
                timestamp: timestamp,
                content: blocks
            ))
        }

        // Build ConversationInfo
        let summary = sessionInfo.title.hasPrefix("New session") ? nil : sessionInfo.title
        let firstUser = firstUserText.map { String($0.prefix(50)) }
        let lastMsg = lastText.map { truncateInline($0, maxLength: 80) }

        let conversationInfo = ConversationInfo(
            summary: summary,
            lastMessage: lastMsg,
            lastMessageRole: chatMessages.last?.role == .user ? "user" : "assistant",
            lastToolName: nil,
            firstUserMessage: firstUser,
            lastUserMessageDate: nil
        )

        return ParseResult(
            messages: chatMessages,
            completedToolIds: completedToolIds,
            toolResults: toolResults,
            conversationInfo: conversationInfo
        )
    }

    // MARK: - SQLite Helpers

    private func openDB() -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(dbPath, &db, flags, nil)
        guard result == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        return db
    }

    private struct SessionInfo {
        let title: String
        let directory: String
        let timeCreated: Int64
    }

    private func querySessionInfo(db: OpaquePointer, sessionId: String) -> SessionInfo {
        let sql = "SELECT title, directory, time_created FROM session WHERE id = ? LIMIT 1"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return SessionInfo(title: "", directory: "", timeCreated: 0)
        }
        sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return SessionInfo(title: "", directory: "", timeCreated: 0)
        }

        let title = String(cString: sqlite3_column_text(stmt, 0))
        let directory = String(cString: sqlite3_column_text(stmt, 1))
        let timeCreated = sqlite3_column_int64(stmt, 2)

        return SessionInfo(title: title, directory: directory, timeCreated: timeCreated)
    }

    private struct RawMessage {
        let id: String
        let role: String
        let timeCreated: Int64
    }

    private func queryMessages(db: OpaquePointer, sessionId: String) -> [RawMessage] {
        let sql = """
            SELECT id, data, time_created FROM message
            WHERE session_id = ?
            ORDER BY time_created ASC, id ASC
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)

        var messages: [RawMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let timeCreated = sqlite3_column_int64(stmt, 2)

            // Parse JSON data to extract role
            var role = "assistant"
            if let dataText = sqlite3_column_text(stmt, 1) {
                let dataStr = String(cString: dataText)
                if let jsonData = dataStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let r = json["role"] as? String {
                    role = r
                }
            }

            messages.append(RawMessage(id: id, role: role, timeCreated: timeCreated))
        }

        return messages
    }

    private struct RawPart {
        let id: String
        let messageId: String
        let data: [String: Any]
        let timeCreated: Int64
    }

    private func queryParts(db: OpaquePointer, sessionId: String) -> [RawPart] {
        let sql = """
            SELECT id, message_id, data, time_created FROM part
            WHERE session_id = ?
            ORDER BY time_created ASC, id ASC
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)

        var parts: [RawPart] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let messageId = String(cString: sqlite3_column_text(stmt, 1))
            let timeCreated = sqlite3_column_int64(stmt, 3)

            var data: [String: Any] = [:]
            if let dataText = sqlite3_column_text(stmt, 2) {
                let dataStr = String(cString: dataText)
                if let jsonData = dataStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    data = json
                }
            }

            parts.append(RawPart(id: id, messageId: messageId, data: data, timeCreated: timeCreated))
        }

        return parts
    }

    // MARK: - Utilities

    private func titleCase(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    private func truncateInline(_ s: String, maxLength: Int) -> String {
        let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if cleaned.count > maxLength {
            return String(cleaned.prefix(maxLength - 3)) + "..."
        }
        return cleaned
    }
}
