//
//  HookInstaller.swift
//  VibeHub
//
//  Auto-installs Claude Code hooks on app launch
//

import Foundation

struct HookInstaller {

#if APP_STORE
    private enum Defaults {
        // Keep key name stable; now stores Home folder bookmark.
        static let claudeDirBookmarkKey = "ci.bookmark.claudeDir"
        static let opencodeDirBookmarkKey = "ci.bookmark.opencodeDir"
    }
#endif

    /// Install hook script and update settings.json on app launch
    static func installIfNeeded() {
#if APP_STORE
        // App Store builds require user-granted directory access.
        // Use `installAppStore(...)` after obtaining security-scoped bookmarks.
        return
#else
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent("vibehub-state.py")
        let settings = claudeDir.appendingPathComponent("settings.json")

        try? FileManager.default.createDirectory(
            at: hooksDir,
            withIntermediateDirectories: true
        )

        if let bundled = Bundle.main.url(forResource: "vibehub-state", withExtension: "py") {
            try? FileManager.default.removeItem(at: pythonScript)
            try? FileManager.default.copyItem(at: bundled, to: pythonScript)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: pythonScript.path
            )
        }

        updateSettings(at: settings)
#endif
    }

    private static func updateSettings(at settingsURL: URL) {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        let python = detectPython()
        let sock = HookSocketServer.socketPath.replacingOccurrences(of: "\"", with: "\\\"")
        let command = "CLAUDE_ISLAND_SOCKET_PATH=\"\(sock)\" \(python) ~/.claude/hooks/vibehub-state.py"
        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let hookEntryWithTimeout: [[String: Any]] = [["type": "command", "command": command, "timeout": 86400]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withMatcherAndTimeout: [[String: Any]] = [["matcher": "*", "hooks": hookEntryWithTimeout]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]
        let preCompactConfig: [[String: Any]] = [
            ["matcher": "auto", "hooks": hookEntry],
            ["matcher": "manual", "hooks": hookEntry]
        ]

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        let hookEvents: [(String, [[String: Any]])] = [
            ("UserPromptSubmit", withoutMatcher),
            ("PreToolUse", withMatcher),
            ("PostToolUse", withMatcher),
            ("PermissionRequest", withMatcherAndTimeout),
            ("Notification", withMatcher),
            ("Stop", withoutMatcher),
            ("SubagentStop", withoutMatcher),
            ("SessionStart", withoutMatcher),
            ("SessionEnd", withoutMatcher),
            ("PreCompact", preCompactConfig),
        ]

        for (event, config) in hookEvents {
            if var existingEvent = hooks[event] as? [[String: Any]] {
                let hasOurHook = existingEvent.contains { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { h in
                            let cmd = h["command"] as? String ?? ""
                            return cmd.contains("vibehub-state.py")
                        }
                    }
                    return false
                }
                if !hasOurHook {
                    existingEvent.append(contentsOf: config)
                    hooks[event] = existingEvent
                }
            } else {
                hooks[event] = config
            }
        }

        json["hooks"] = hooks

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: settingsURL)
        }
    }

    /// Check if hooks are currently installed
    static func isInstalled() -> Bool {
#if APP_STORE
        guard let homeDir = resolveBookmark(key: Defaults.claudeDirBookmarkKey) else {
            return false
        }
        // The bookmark stores the Home directory, not ~/.claude directly.
        let claudeDir = homeDir.appendingPathComponent(".claude")
        return withSecurityScope(url: homeDir) {
            isInstalledInClaudeDir(claudeDir)
        } ?? false
#else
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let settings = claudeDir.appendingPathComponent("settings.json")

        guard let data = try? Data(contentsOf: settings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        for (_, value) in hooks {
            if let entries = value as? [[String: Any]] {
                for entry in entries {
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        for hook in entryHooks {
                            if let cmd = hook["command"] as? String,
                               cmd.contains("vibehub-state.py") {
                                return true
                            }
                        }
                    }
                }
            }
        }
        return false
#endif
    }

    /// Uninstall hooks from settings.json and remove script
    static func uninstall() {
#if APP_STORE
        // Prefer uninstallAppStore() since it can remove OpenCode plugin too.
        _ = uninstallAppStore()
        return
#else
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent("vibehub-state.py")
        let settings = claudeDir.appendingPathComponent("settings.json")

        try? FileManager.default.removeItem(at: pythonScript)

        guard let data = try? Data(contentsOf: settings),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            if var entries = value as? [[String: Any]] {
                entries.removeAll { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { hook in
                            let cmd = hook["command"] as? String ?? ""
                            return cmd.contains("vibehub-state.py")
                        }
                    }
                    return false
                }

                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: settings)
        }
#endif
    }

#if APP_STORE

    // MARK: - App Store (Sandbox) install/uninstall

    /// Stores a security-scoped bookmark for future installs.
    static func rememberClaudeDir(_ url: URL) -> Bool {
        storeBookmark(for: url, key: Defaults.claudeDirBookmarkKey)
    }

    /// Stores a security-scoped bookmark for OpenCode config directory.
    static func rememberOpenCodeDir(_ url: URL) -> Bool {
        storeBookmark(for: url, key: Defaults.opencodeDirBookmarkKey)
    }

    /// Installs Claude Code hooks into the provided Claude dir (usually ~/.claude).
    /// Caller must have an active security scope for claudeDir.
    static func installAppStore(claudeDir: URL) -> Bool {
        let hooksDir = claudeDir.appendingPathComponent("hooks", isDirectory: true)
        let pythonScript = hooksDir.appendingPathComponent("vibehub-state.py")
        let settings = claudeDir.appendingPathComponent("settings.json")

        do {
            try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        } catch {
            return false
        }

        guard let bundled = Bundle.main.url(forResource: "vibehub-state", withExtension: "py") else {
            return false
        }

        do {
            try? FileManager.default.removeItem(at: pythonScript)
            try FileManager.default.copyItem(at: bundled, to: pythonScript)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pythonScript.path)
        } catch {
            return false
        }

        updateSettings(at: settings)
        return true
    }

    /// Installs OpenCode plugin into the provided OpenCode config dir (usually ~/.config/opencode).
    /// Caller must have an active security scope for opencodeDir.
    static func installOpenCodeAppStore(opencodeDir: URL) -> Bool {
        let configFile = opencodeDir.appendingPathComponent("opencode.json")
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            // Treat missing OpenCode config as a no-op; user may not use OpenCode.
            return true
        }

        let pluginsDir = opencodeDir.appendingPathComponent("plugins", isDirectory: true)
        let pluginFile = pluginsDir.appendingPathComponent("vibehub.js")
        let socketFile = pluginsDir.appendingPathComponent("vibehub.socket")

        do {
            try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        } catch {
            return false
        }

        guard let bundled = Bundle.main.url(forResource: "vibehub-opencode", withExtension: "js") else {
            return false
        }

        do {
            try? FileManager.default.removeItem(at: pluginFile)
            try FileManager.default.copyItem(at: bundled, to: pluginFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pluginFile.path)

            // Sidecar socket path for strict OpenCode configs (no env key support).
            let p = HookSocketServer.socketPath + "\n"
            try p.data(using: .utf8)?.write(to: socketFile, options: [.atomic])
        } catch {
            return false
        }

        return updateOpenCodeConfig(configFile: configFile, pluginFile: pluginFile)
    }

    /// Uninstalls hooks using stored bookmarks (best effort).
    static func uninstallAppStore() -> Bool {
        var ok = true
        if let homeDir = resolveBookmark(key: Defaults.claudeDirBookmarkKey) {
            // The bookmark stores the Home directory, not ~/.claude directly.
            let claudeDir = homeDir.appendingPathComponent(".claude")
            let removed = withSecurityScope(url: homeDir) {
                uninstallInClaudeDir(claudeDir)
            } ?? false
            ok = ok && removed
        }
        if let homeDir = resolveBookmark(key: Defaults.claudeDirBookmarkKey) {
            // OpenCode config is also a descendant of Home.
            let opencodeDir = homeDir
                .appendingPathComponent(".config")
                .appendingPathComponent("opencode")
            let removed = withSecurityScope(url: homeDir) {
                uninstallOpenCodeInDir(opencodeDir)
            } ?? false
            ok = ok && removed
        }
        return ok
    }

    // MARK: - Helpers

    private static func isInstalledInClaudeDir(_ claudeDir: URL) -> Bool {
        let settings = claudeDir.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: settings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }
        for (_, value) in hooks {
            if let entries = value as? [[String: Any]] {
                for entry in entries {
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        for hook in entryHooks {
                            if let cmd = hook["command"] as? String,
                               cmd.contains("vibehub-state.py") {
                                return true
                            }
                        }
                    }
                }
            }
        }
        return false
    }

    private static func uninstallInClaudeDir(_ claudeDir: URL) -> Bool {
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent("vibehub-state.py")
        let settings = claudeDir.appendingPathComponent("settings.json")
        try? FileManager.default.removeItem(at: pythonScript)

        guard let data = try? Data(contentsOf: settings),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return true
        }

        for (event, value) in hooks {
            if var entries = value as? [[String: Any]] {
                entries.removeAll { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { hook in
                            let cmd = hook["command"] as? String ?? ""
                            return cmd.contains("vibehub-state.py")
                        }
                    }
                    return false
                }

                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: settings)
        }
        return true
    }

    private static func uninstallOpenCodeInDir(_ opencodeDir: URL) -> Bool {
        let pluginsDir = opencodeDir.appendingPathComponent("plugins")
        let pluginFile = pluginsDir.appendingPathComponent("vibehub.js")
        let socketFile = pluginsDir.appendingPathComponent("vibehub.socket")
        try? FileManager.default.removeItem(at: pluginFile)
        try? FileManager.default.removeItem(at: socketFile)

        let configFile = opencodeDir.appendingPathComponent("opencode.json")
        guard let data = try? Data(contentsOf: configFile),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return true
        }

        let pluginURL = URL(fileURLWithPath: pluginFile.path).absoluteString
        if var plugins = json["plugin"] as? [String] {
            plugins.removeAll { $0 == pluginURL }
            json["plugin"] = plugins
        } else if let p = json["plugin"] as? String, p == pluginURL {
            json.removeValue(forKey: "plugin")
        }

        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: configFile)
        }
        return true
    }

    private static func updateOpenCodeConfig(configFile: URL, pluginFile: URL) -> Bool {
        guard let data = try? Data(contentsOf: configFile),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }

        let pluginURL = URL(fileURLWithPath: pluginFile.path).absoluteString

        var plugins: [String] = []
        if let existing = json["plugin"] as? [String] {
            plugins = existing
        } else if let existing = json["plugin"] as? String {
            plugins = [existing]
        }

        if !plugins.contains(pluginURL) {
            plugins.append(pluginURL)
        }
        json["plugin"] = plugins

        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        do {
            try out.write(to: configFile)
            return true
        } catch {
            return false
        }
    }

    private static func storeBookmark(for url: URL, key: String) -> Bool {
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: key)
            return true
        } catch {
            return false
        }
    }

    private static func resolveBookmark(key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        do {
            return try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            return nil
        }
    }

    private static func withSecurityScope<T>(url: URL, _ block: () -> T) -> T? {
        let ok = url.startAccessingSecurityScopedResource()
        guard ok else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        return block()
    }

#endif

    private static func detectPython() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "python3"
            }
        } catch {}

        return "python"
    }
}
