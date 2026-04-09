//
//  CodexHookInstaller.swift
//  VibeHub
//
//  Installs hooks for Codex CLI (~/.codex/hooks.json + config.toml).
//  Reuses the same vibehub-state.py script as Claude Code.
//

import Foundation

struct CodexHookInstaller {

    private static let codexEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop",
    ]

    // MARK: - Install

    static func installIfNeeded() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexDir = home.appendingPathComponent(".codex")
        guard FileManager.default.fileExists(atPath: codexDir.path) else { return }

        installHookScript(codexDir: codexDir)
        updateHooksJson(codexDir: codexDir)
        enableCodexHooksConfig(codexDir: codexDir)
    }

    private static func installHookScript(codexDir: URL) {
        let hooksDir = codexDir.appendingPathComponent("hooks")
        let dst = hooksDir.appendingPathComponent("vibehub-state.py")

        try? FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        // Symlink to the shared script in ~/.vibehub/ (installed by HookInstaller).
        HookInstaller.ensureSymlink(at: dst, target: HookInstaller.sharedScriptURL)
    }

    private static func updateHooksJson(codexDir: URL) {
        let hooksJsonURL = codexDir.appendingPathComponent("hooks.json")
        let python = HookInstaller.detectPython()
        let sock = HookSocketPaths.socketPath.replacingOccurrences(of: "\"", with: "\\\"")
        let command = "VIBEHUB_SOURCE=codex VIBEHUB_SOCKET_PATH=\"\(sock)\" \(python) ~/.codex/hooks/vibehub-state.py"

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: hooksJsonURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]

        for event in codexEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            // Remove stale VibeHub entries
            entries.removeAll { entry in
                guard let hs = entry["hooks"] as? [[String: Any]] else { return false }
                return hs.contains { ($0["command"] as? String ?? "").contains("vibehub-state.py") }
            }
            // Nested format (no matcher, with timeout)
            entries.append(["hooks": [["type": "command", "command": command, "timeout": 5] as [String: Any]]])
            hooks[event] = entries
        }

        root["hooks"] = hooks

        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: hooksJsonURL)
        }
    }

    /// Ensure `codex_hooks = true` under `[features]` in ~/.codex/config.toml
    private static func enableCodexHooksConfig(codexDir: URL) {
        let configPath = codexDir.appendingPathComponent("config.toml").path
        var contents = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""

        // Already set to true
        if contents.range(of: #"(?m)^\s*codex_hooks\s*=\s*true"#, options: .regularExpression) != nil {
            return
        }

        // Set to false — flip it
        if contents.range(of: #"(?m)^\s*codex_hooks\s*=\s*false"#, options: .regularExpression) != nil {
            contents = contents.replacingOccurrences(
                of: #"(?m)^\s*codex_hooks\s*=\s*false"#,
                with: "codex_hooks = true",
                options: .regularExpression
            )
            try? contents.write(toFile: configPath, atomically: true, encoding: .utf8)
            return
        }

        // Not present — insert into [features] or append section
        var lines = contents.components(separatedBy: "\n")
        if let idx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[features]" }) {
            lines.insert("codex_hooks = true", at: idx + 1)
        } else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append("[features]")
            lines.append("codex_hooks = true")
        }
        try? lines.joined(separator: "\n").write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Uninstall

    static func uninstall() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexDir = home.appendingPathComponent(".codex")
        uninstallInDir(codexDir)
    }

    static func uninstallInDir(_ codexDir: URL) {
        let script = codexDir.appendingPathComponent("hooks").appendingPathComponent("vibehub-state.py")
        try? FileManager.default.removeItem(at: script)

        let hooksJsonURL = codexDir.appendingPathComponent("hooks.json")
        guard let data = try? Data(contentsOf: hooksJsonURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any] else { return }

        for (event, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll { entry in
                guard let hs = entry["hooks"] as? [[String: Any]] else { return false }
                return hs.contains { ($0["command"] as? String ?? "").contains("vibehub-state.py") }
            }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }

        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: hooksJsonURL)
        }
    }

    // MARK: - App Store

#if APP_STORE
    static func installCodexAppStore(codexDir: URL) -> Bool {
        installHookScript(codexDir: codexDir)
        updateHooksJson(codexDir: codexDir)
        enableCodexHooksConfig(codexDir: codexDir)
        return true
    }
#endif
}
