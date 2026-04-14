//
//  MCPToolFormatter.swift
//  VibeHub
//
//  Utility for formatting MCP tool names, arguments, and colors.
//

import Foundation
import SwiftUI

struct MCPToolFormatter {

    /// Accent color used for a tool call in the chat view, the notch list
    /// description row, and anywhere else we render a tool name. Having a
    /// single source of truth means the instance row and chat view always
    /// agree on what color represents `Bash`, `Edit`, `Grep`, etc.
    ///
    /// Matches Claude's canonical tool vocabulary AND the native names used
    /// by OpenCode (lowercased, then titleCased by the plugin) and Codex
    /// (`shell`, `apply_patch`, `update_plan`, `read_file`, …), so every
    /// supported CLI ends up with a colored tool row.
    static func color(for toolName: String) -> Color {
        // Normalize for case-insensitive matching (Codex uses snake_case,
        // OpenCode hand-rolls camelCase in some paths).
        let lower = toolName.lowercased()

        switch toolName {
        // Claude vocabulary
        case "Read":
            return Color.cyan
        case "Edit", "Write", "NotebookEdit":
            return Color.orange
        case "Bash", "BashOutput", "KillShell":
            return Color.green
        case "Grep", "Glob":
            return Color.yellow
        case "Agent", "Task", "AgentOutputTool":
            return Color.indigo.opacity(0.8)
        case "WebSearch", "WebFetch":
            return Color.blue
        case "AskUserQuestion":
            return Color.mint
        default:
            break
        }

        // Codex + OpenCode native names
        switch lower {
        case "shell", "exec", "local_shell", "local_shell_call":
            return Color.green
        case "apply_patch", "patch", "edit_file", "write_file":
            return Color.orange
        case "read_file", "view", "read":
            return Color.cyan
        case "grep", "search", "search_files":
            return Color.yellow
        case "glob", "list", "list_files":
            return Color.yellow
        case "web_search", "web_fetch", "fetch", "search_web":
            return Color.blue
        case "update_plan", "plan":
            return Color.indigo.opacity(0.8)
        default:
            break
        }

        if isMCPTool(toolName) {
            return Color.teal
        }
        return .primary.opacity(0.8)
    }

    /// Tool aliases for friendlier display names
    private static let toolAliases: [String: String] = [
        "AgentOutputTool": "Await Agent",
        "AskUserQuestion": "Question",
        "TodoWrite": "Todo",
        "TodoRead": "Todo",
        "WebFetch": "Fetch",
        "WebSearch": "Search",
        "NotebookEdit": "Notebook",
        "BashOutput": "Bash",
        "KillShell": "Shell",
        "EnterPlanMode": "Plan",
        "ExitPlanMode": "Plan",
        "SlashCommand": "Command",
    ]

    /// Checks if tool name is in MCP format (e.g., "mcp__deepwiki__ask_question")
    static func isMCPTool(_ name: String) -> Bool {
        name.hasPrefix("mcp__")
    }

    /// Short, human-readable preview of a tool call's input. Used in the
    /// ChatView tool row header AND in the notch list description line so
    /// both surfaces show the same one-line summary.
    ///
    /// Prefers the most meaningful field per tool (Bash → command,
    /// Read/Edit → file_path, Grep → pattern, …) and falls back to
    /// `formatArgs` for anything unknown. Returns `nil` when there's
    /// nothing useful to display.
    ///
    /// Works across all supported CLIs:
    ///   - Claude / forks use snake_case keys (`file_path`, `tool_use_id`).
    ///   - OpenCode's JS plugin forwards some parts camelCase (`filePath`).
    ///   - Codex uses its own native tool names (`shell`, `apply_patch`,
    ///     `read_file`, …) with argv-array commands.
    /// All three shapes are handled here.
    static func previewText(toolName: String, input: [String: String]) -> String? {
        guard !input.isEmpty else { return nil }

        // Try several keys in order; return the first non-empty value.
        func first(_ keys: String...) -> String? {
            for key in keys {
                if let v = input[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !v.isEmpty {
                    return v
                }
            }
            return nil
        }

        // Shared field lookups that cover snake_case + camelCase variants.
        let filePathValue = first("file_path", "filePath", "path")
        let commandValue = first("command", "cmd")
        let patternValue = first("pattern", "regex", "query")

        switch toolName {
        // Claude vocabulary
        case "Bash", "BashOutput", "KillShell":
            return commandValue ?? first("description")
        case "Read", "Write":
            return filePathValue
        case "Edit", "NotebookEdit":
            return filePathValue ?? first("notebook_path", "notebookPath")
        case "Grep":
            if let pattern = patternValue {
                if let path = first("path", "include") {
                    return "\(pattern)  ·  \(path)"
                }
                return pattern
            }
            return nil
        case "Glob":
            return patternValue
        case "WebFetch":
            return first("url")
        case "WebSearch":
            return first("query", "q")
        case "Task":
            return first("description", "subagent_type", "subagentType")
        case "TodoWrite", "TodoRead":
            return nil
        case "AskUserQuestion":
            return first("question", "text")
        case "SlashCommand":
            return commandValue
        case "ExitPlanMode", "EnterPlanMode":
            return first("plan")
        default:
            break
        }

        // Codex native tool names. Codex passes `shell.command` as an
        // already-JSON-encoded argv array (e.g. `["bash","-lc","ls -la"]`)
        // which Codex-rollout-parser flattens into a string. We also handle
        // `apply_patch.input` which is the raw patch body, and plan updates.
        let lower = toolName.lowercased()
        switch lower {
        case "shell", "exec", "local_shell", "local_shell_call":
            if let cmd = commandValue { return cmd }
            // Fallback to the raw argv-array serialization if present.
            if let argv = first("argv") { return argv }
            return nil
        case "apply_patch", "patch":
            // Custom tool call — Codex stores the raw patch in "input".
            if let patch = first("input") {
                // Show just the first non-empty line so long patches don't
                // blow up the row height.
                let firstLine = patch.split(whereSeparator: { $0 == "\n" }).first.map(String.init)
                return firstLine ?? patch
            }
            return nil
        case "read_file", "view":
            return filePathValue
        case "edit_file", "write_file":
            return filePathValue
        case "search", "search_files":
            return patternValue ?? first("path")
        case "list", "list_files":
            return first("path") ?? patternValue
        case "web_search", "search_web":
            return first("query", "q")
        case "web_fetch", "fetch":
            return first("url")
        case "update_plan", "plan":
            return first("plan", "description")
        default:
            break
        }

        if isMCPTool(toolName) {
            return formatArgs(input)
        }
        // Unknown tool — fall back to formatted args when available.
        let args = formatArgs(input)
        return args.isEmpty ? nil : args
    }

    /// Converts snake_case to Title Case
    /// e.g., "ask_question" → "Ask Question"
    static func toTitleCase(_ snakeCase: String) -> String {
        snakeCase
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    /// Formats MCP tool ID to human-readable format
    /// e.g., "mcp__deepwiki__ask_question" → "Deepwiki - Ask Question"
    /// Returns alias if available, otherwise original name
    static func formatToolName(_ toolId: String) -> String {
        // Check for alias first
        if let alias = toolAliases[toolId] {
            return alias
        }

        guard isMCPTool(toolId) else { return toolId }

        // Remove "mcp__" prefix and split by "__"
        let withoutPrefix = String(toolId.dropFirst(5)) // Drop "mcp__"
        let parts = withoutPrefix.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: true)

        guard parts.count >= 1 else { return toolId }

        let serverName = toTitleCase(String(parts[0]))

        if parts.count >= 2 {
            // The second part starts with "_" which we need to drop
            let toolNameRaw = String(parts[1]).hasPrefix("_")
                ? String(String(parts[1]).dropFirst())
                : String(parts[1])
            let toolName = toTitleCase(toolNameRaw)
            return "\(serverName) - \(toolName)"
        }

        return serverName
    }

    /// Formats tool input dictionary for display
    /// e.g., ["repoName": "facebook/react", "question": "How does..."] → `repoName: "facebook/react", question: "How does..."`
    /// Truncates long values and limits number of args shown
    static func formatArgs(_ input: [String: String], maxValueLength: Int = 30, maxArgs: Int = 3) -> String {
        guard !input.isEmpty else { return "" }

        let sortedKeys = input.keys.sorted()
        var formattedParts: [String] = []

        for key in sortedKeys.prefix(maxArgs) {
            guard let value = input[key] else { continue }

            let truncatedValue: String
            if value.count > maxValueLength {
                truncatedValue = String(value.prefix(maxValueLength)) + "..."
            } else {
                truncatedValue = value
            }

            formattedParts.append("\(key): \"\(truncatedValue)\"")
        }

        var result = formattedParts.joined(separator: ", ")

        if sortedKeys.count > maxArgs {
            result += ", ..."
        }

        return result
    }

    /// Formats tool input from Any dictionary (handles both String and non-String values)
    static func formatArgs(_ input: [String: Any], maxValueLength: Int = 30, maxArgs: Int = 3) -> String {
        guard !input.isEmpty else { return "" }

        let sortedKeys = input.keys.sorted()
        var formattedParts: [String] = []

        for key in sortedKeys.prefix(maxArgs) {
            guard let value = input[key] else { continue }

            let stringValue: String
            if let str = value as? String {
                stringValue = str
            } else if let num = value as? NSNumber {
                stringValue = num.stringValue
            } else if let bool = value as? Bool {
                stringValue = bool ? "true" : "false"
            } else {
                stringValue = String(describing: value)
            }

            let truncatedValue: String
            if stringValue.count > maxValueLength {
                truncatedValue = String(stringValue.prefix(maxValueLength)) + "..."
            } else {
                truncatedValue = stringValue
            }

            formattedParts.append("\(key): \"\(truncatedValue)\"")
        }

        var result = formattedParts.joined(separator: ", ")

        if sortedKeys.count > maxArgs {
            result += ", ..."
        }

        return result
    }
}
