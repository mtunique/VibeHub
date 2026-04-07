//
//  HookInstaller.swift
//  VibeHub
//
//  Auto-installs Claude Code hooks on app launch
//

import Combine
import Foundation
import os.log

struct HookInstaller {

    // MARK: - Settings file watcher

    private static let watchLogger = Logger(subsystem: "com.vibehub", category: "HookInstaller")
    private static var settingsSource: DispatchSourceFileSystemObject?
    private static var settingsFd: Int32 = -1

    /// Observable hook-installed state. UI binds to this instead of polling `isInstalled()`.
    static let installedSubject = CurrentValueSubject<Bool, Never>(isInstalled())

    /// Start watching ~/.claude/settings.json and update `installedSubject` on changes.
    static func startWatchingSettings() {
    #if APP_STORE
        return
    #else
        stopWatchingSettings()

        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json").path

        let fd = open(settingsPath, O_EVTONLY)
        guard fd >= 0 else {
            watchLogger.warning("Cannot open settings.json for watching")
            return
        }
        settingsFd = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler {
            let installed = isInstalled()
            installedSubject.send(installed)
            if !installed {
                watchLogger.info("Hooks removed from settings.json by external process")
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        settingsSource = source
        source.resume()
        watchLogger.info("Watching settings.json for hook changes")
    #endif
    }

    static func stopWatchingSettings() {
        settingsSource?.cancel()
        settingsSource = nil
        settingsFd = -1
    }

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
        // If we already have a stored bookmark, use it to auto-update hooks
        // (ensures socket path stays correct across build switches).
        if let homeDir = resolveBookmark(key: Defaults.claudeDirBookmarkKey) {
            _ = withSecurityScope(url: homeDir) {
                let claudeDir = homeDir.appendingPathComponent(".claude")
                _ = installAppStore(claudeDir: claudeDir)

                let opencodeDir = homeDir.appendingPathComponent(".config").appendingPathComponent("opencode")
                if FileManager.default.fileExists(atPath: opencodeDir.path) {
                    _ = installOpenCodeAppStore(opencodeDir: opencodeDir)
                }
            }
        }
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
                // Remove any stale vibehub hooks (e.g. from a different build
                // with a different socket path) before inserting ours.
                existingEvent.removeAll { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { h in
                            let cmd = h["command"] as? String ?? ""
                            return cmd.contains("vibehub-state.py")
                        }
                    }
                    return false
                }
                existingEvent.append(contentsOf: config)
                hooks[event] = existingEvent
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
            installedSubject.send(true)
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
        installedSubject.send(false)
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
    /// Plugins in ~/.config/opencode/plugins/ are auto-discovered — no opencode.json registration needed.
    static func installOpenCodeAppStore(opencodeDir: URL) -> Bool {
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

            // Sidecar socket path so the plugin knows where to connect.
            let p = HookSocketServer.socketPath + "\n"
            try p.data(using: .utf8)?.write(to: socketFile, options: [.atomic])
        } catch {
            return false
        }

        return true
    }

    /// Returns the real user home directory URL resolved from the stored bookmark, or nil if unavailable.
    static func resolvedHomeDirectory() -> URL? {
        resolveBookmark(key: Defaults.claudeDirBookmarkKey)
    }

    /// Returns the real home directory path, falling back to NSHomeDirectory() in sandbox.
    static func resolvedHomePath() -> String {
        resolvedHomeDirectory()?.path ?? NSHomeDirectory()
    }

    /// Execute a block with security-scoped access to the user's real home directory.
    /// Returns nil if no bookmark is stored or security scope cannot be obtained.
    static func withResolvedHome<T>(_ block: (URL) -> T) -> T? {
        guard let homeDir = resolveBookmark(key: Defaults.claudeDirBookmarkKey) else { return nil }
        return withSecurityScope(url: homeDir) { block(homeDir) }
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
        return true
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
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale {
                _ = storeBookmark(for: url, key: key)
            }
            return url
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
