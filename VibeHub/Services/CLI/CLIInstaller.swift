//
//  CLIInstaller.swift
//  VibeHub
//
//  Unified installer that consumes `CLIConfig.all` and drives both local
//  and remote installation. Replaces the per-CLI logic previously scattered
//  across HookInstaller / CodexHookInstaller / OpenCodePluginInstaller.
//
//  Non-App-Store builds install directly into `~/.<configDir>`. App Store
//  builds still flow through `HookInstaller.installAppStore(claudeDir:)`
//  style helpers because of sandbox bookmark handling — those wrappers
//  delegate to the same `installClaudeStyle(config:homeDir:)` primitive.
//

import CryptoKit
import Foundation
import os.log

enum CLIInstaller {

    private static let logger = Logger(subsystem: "com.vibehub", category: "CLIInstaller")

    // MARK: - Local install (non-App-Store)

    /// Install hooks/plugins for every `CLIConfig.all` entry whose config
    /// directory exists. Non-existent configs are skipped silently.
    static func installAllLocal() {
        let home = FileManager.default.homeDirectoryForCurrentUser

        // Shared Python script sits at ~/.vibehub/vibehub-state.py.
        installSharedScript()

        for config in CLIConfig.all {
            installLocal(config: config, homeDir: home)
        }
    }

    /// Remove hooks/plugins across every known CLI.
    static func uninstallAllLocal() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for config in CLIConfig.all {
            uninstallLocal(config: config, homeDir: home)
        }
        // Remove shared script last (after every symlink has been cleared).
        try? FileManager.default.removeItem(at: sharedScriptURL)
    }

    /// True if ANY Claude/Codex-style settings file currently contains a
    /// `vibehub-state.py` command entry, or if the OpenCode plugin file exists.
    static func isAnyInstalled() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for config in CLIConfig.all {
            if isInstalled(config: config, homeDir: home) {
                return true
            }
        }
        return false
    }

    // MARK: - Per-config dispatch

    static func installLocal(config: CLIConfig, homeDir: URL) {
        let configDir = homeDir.appendingPathComponent(config.configDirRelative)
        // Only install if the CLI's config directory exists; we never create
        // `~/.codex/` for users who don't have Codex installed.
        guard FileManager.default.fileExists(atPath: configDir.path) else { return }

        switch config.installKind {
        case .claudeStyleHook:
            installClaudeStyle(config: config, configDir: configDir)
        case .codexStyleHook:
            installCodexStyle(config: config, configDir: configDir)
        case .opencodePlugin:
            installOpenCodePlugin(config: config, configDir: configDir)
        }
    }

    static func uninstallLocal(config: CLIConfig, homeDir: URL) {
        let configDir = homeDir.appendingPathComponent(config.configDirRelative)
        guard FileManager.default.fileExists(atPath: configDir.path) else { return }

        switch config.installKind {
        case .claudeStyleHook:
            uninstallClaudeStyle(config: config, configDir: configDir)
        case .codexStyleHook:
            uninstallCodexStyle(config: config, configDir: configDir)
        case .opencodePlugin:
            uninstallOpenCodePlugin(config: config, configDir: configDir)
        }
    }

    static func isInstalled(config: CLIConfig, homeDir: URL) -> Bool {
        let configDir = homeDir.appendingPathComponent(config.configDirRelative)
        guard FileManager.default.fileExists(atPath: configDir.path) else { return false }

        switch config.installKind {
        case .claudeStyleHook, .codexStyleHook:
            guard let settingsFile = config.settingsFileRelative else { return false }
            let settingsURL = configDir.appendingPathComponent(settingsFile)
            return settingsContainsVibehub(at: settingsURL)
        case .opencodePlugin:
            let pluginFile = configDir.appendingPathComponent("plugins/vibehub.js")
            return FileManager.default.fileExists(atPath: pluginFile.path)
        }
    }

    /// Whether the CLI itself is present on disk (its config directory
    /// exists). Used by the settings page to distinguish "CLI not installed"
    /// from "CLI installed but VibeHub hook not registered".
    static func configDirExists(config: CLIConfig, homeDir: URL) -> Bool {
        let configDir = homeDir.appendingPathComponent(config.configDirRelative)
        return FileManager.default.fileExists(atPath: configDir.path)
    }

    /// Single-row snapshot of how a CLI sits on this machine.
    struct InstallStatus: Identifiable, Sendable {
        let source: SupportedCLI
        let configExists: Bool
        let hookInstalled: Bool
        var id: SupportedCLI { source }
    }

    /// Per-CLI install status for every entry in `CLIConfig.all`. Non-App-Store
    /// build — reads the real home directory directly. App Store callers should
    /// use `HookInstaller.perCLIStatus()` which handles the sandbox bookmark.
    static func perCLIStatus() -> [InstallStatus] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return CLIConfig.all.map { cfg in
            InstallStatus(
                source: cfg.source,
                configExists: configDirExists(config: cfg, homeDir: home),
                hookInstalled: isInstalled(config: cfg, homeDir: home)
            )
        }
    }

    // MARK: - Shared script

    /// Content hash of the bundled `vibehub-state.py` hook.
    /// Used by RemoteInstaller to decide whether to upload a fresh copy.
    /// Matches the output of `vibehub-state.py --version` (SHA-256, first 16 hex chars).
    static let sharedScriptVersion: String = {
        guard let url = Bundle.main.url(forResource: "vibehub-state", withExtension: "py"),
              let data = try? Data(contentsOf: url) else { return "unknown" }
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }()

    /// Canonical location of the shared Python hook script. Every CLI's
    /// `hooks/vibehub-state.py` is a symlink pointing here.
    static let sharedScriptURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".vibehub", isDirectory: true)
        .appendingPathComponent("vibehub-state.py")

    static func installSharedScript() {
        let fm = FileManager.default
        let dir = sharedScriptURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        guard let bundled = Bundle.main.url(forResource: "vibehub-state", withExtension: "py") else {
            return
        }
        try? fm.removeItem(at: sharedScriptURL)
        try? fm.copyItem(at: bundled, to: sharedScriptURL)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sharedScriptURL.path)
    }

    static func ensureSymlink(at link: URL, target: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: link)
        try? fm.createSymbolicLink(at: link, withDestinationURL: target)
    }

    // MARK: - Python detection

    /// Cached result of resolving `python3` on PATH. The answer is stable
    /// for the process lifetime, and `detectPython` used to be called once
    /// per CLI per install which spawned a subprocess each time.
    private static let cachedPython: String = {
        if ProcessExecutor.shared.runSyncOrNil("/usr/bin/which", arguments: ["python3"]) != nil {
            return "python3"
        }
        return "python"
    }()

    static func detectPython() -> String { cachedPython }

    // MARK: - Claude-style hook install (settings.json merge)

    /// Install a CLI that uses Claude-compatible hook schema:
    /// symlink + merge `settings.json`. Works for Claude itself and every
    /// Claude fork that shares the same settings layout.
    static func installClaudeStyle(config: CLIConfig, configDir: URL) {
        guard let hooksSubdir = config.hooksSubdirRelative,
              let settingsRel = config.settingsFileRelative else { return }

        let hooksDir = configDir.appendingPathComponent(hooksSubdir)
        let scriptLink = hooksDir.appendingPathComponent("vibehub-state.py")
        let settingsFile = configDir.appendingPathComponent(settingsRel)

        try? FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        ensureSymlink(at: scriptLink, target: sharedScriptURL)

        mergeSettingsJSON(
            at: settingsFile,
            config: config,
            scriptPathRelative: "~/\(config.configDirRelative)/\(hooksSubdir)/vibehub-state.py",
            useFlatSchema: false
        )
    }

    /// Codex-style install: same symlink pattern as Claude-style but writes
    /// into `hooks.json` (flat schema), then flips the TOML feature flag.
    static func installCodexStyle(config: CLIConfig, configDir: URL) {
        guard let hooksSubdir = config.hooksSubdirRelative,
              let settingsRel = config.settingsFileRelative else { return }

        let hooksDir = configDir.appendingPathComponent(hooksSubdir)
        let scriptLink = hooksDir.appendingPathComponent("vibehub-state.py")
        let hooksJSON = configDir.appendingPathComponent(settingsRel)

        try? FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        ensureSymlink(at: scriptLink, target: sharedScriptURL)

        mergeSettingsJSON(
            at: hooksJSON,
            config: config,
            scriptPathRelative: "~/\(config.configDirRelative)/\(hooksSubdir)/vibehub-state.py",
            useFlatSchema: true
        )

        if let toggle = config.tomlFeatureToggle {
            applyTOMLFeatureToggle(
                at: configDir.appendingPathComponent(toggle.file),
                section: toggle.section,
                key: toggle.key
            )
        }
    }

    /// OpenCode-style install: copy plugin JS + sidecar socket path.
    static func installOpenCodePlugin(config: CLIConfig, configDir: URL) {
        let pluginsDir = configDir.appendingPathComponent("plugins", isDirectory: true)
        let pluginFile = pluginsDir.appendingPathComponent("vibehub.js")
        let socketFile = pluginsDir.appendingPathComponent("vibehub.socket")

        do {
            try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        } catch {
            return
        }

        guard let bundled = Bundle.main.url(forResource: "vibehub-opencode", withExtension: "js") else {
            return
        }

        do {
            try? FileManager.default.removeItem(at: pluginFile)
            try FileManager.default.copyItem(at: bundled, to: pluginFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pluginFile.path)

            let sp = HookSocketPaths.socketPath + "\n"
            try sp.data(using: .utf8)?.write(to: socketFile, options: [.atomic])
        } catch {
            return
        }
    }

    // MARK: - Uninstallers

    static func uninstallClaudeStyle(config: CLIConfig, configDir: URL) {
        guard let hooksSubdir = config.hooksSubdirRelative,
              let settingsRel = config.settingsFileRelative else { return }

        let scriptLink = configDir.appendingPathComponent(hooksSubdir).appendingPathComponent("vibehub-state.py")
        let settingsFile = configDir.appendingPathComponent(settingsRel)

        try? FileManager.default.removeItem(at: scriptLink)
        removeVibehubFromSettings(at: settingsFile, useFlatSchema: false)
    }

    static func uninstallCodexStyle(config: CLIConfig, configDir: URL) {
        guard let hooksSubdir = config.hooksSubdirRelative,
              let settingsRel = config.settingsFileRelative else { return }

        let scriptLink = configDir.appendingPathComponent(hooksSubdir).appendingPathComponent("vibehub-state.py")
        let hooksJSON = configDir.appendingPathComponent(settingsRel)

        try? FileManager.default.removeItem(at: scriptLink)
        removeVibehubFromSettings(at: hooksJSON, useFlatSchema: true)
    }

    static func uninstallOpenCodePlugin(config: CLIConfig, configDir: URL) {
        let pluginFile = configDir.appendingPathComponent("plugins/vibehub.js")
        let socketFile = configDir.appendingPathComponent("plugins/vibehub.socket")
        try? FileManager.default.removeItem(at: pluginFile)
        try? FileManager.default.removeItem(at: socketFile)
    }

    // MARK: - settings.json merger

    /// Merge our hook entries into a JSON settings file.
    /// - Parameter useFlatSchema: `true` for Codex-style nested-hooks-only
    ///   entries (`[{"hooks":[...]}]`), `false` for Claude-style wrapped
    ///   entries (`[{"matcher": "*", "hooks":[...]}]`).
    static func mergeSettingsJSON(
        at settingsURL: URL,
        config: CLIConfig,
        scriptPathRelative: String,
        useFlatSchema: Bool
    ) {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        let python = detectPython()
        let sock = HookSocketPaths.socketPath.replacingOccurrences(of: "\"", with: "\\\"")
        let command = "VIBEHUB_SOURCE=\(config.envSource) VIBEHUB_SOCKET_PATH=\"\(sock)\" \(python) \(scriptPathRelative)"

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        for event in config.hookEvents {
            let entryConfig: [[String: Any]]
            if useFlatSchema {
                // Codex schema: {"hooks": [{type, command, timeout}]}
                var hookEntry: [String: Any] = ["type": "command", "command": command]
                if let timeout = event.timeoutSeconds {
                    hookEntry["timeout"] = timeout
                }
                entryConfig = [["hooks": [hookEntry]]]
            } else if let matchers = event.preCompactMatchers {
                // Claude PreCompact: multiple matcher entries.
                let hookEntry: [String: Any] = ["type": "command", "command": command]
                entryConfig = matchers.map { m in
                    ["matcher": m, "hooks": [hookEntry]]
                }
            } else {
                // Claude standard: single matcher entry or no-matcher wrapper.
                var hookEntry: [String: Any] = ["type": "command", "command": command]
                if let timeout = event.timeoutSeconds {
                    hookEntry["timeout"] = timeout
                }
                if let matcher = event.matcher {
                    entryConfig = [["matcher": matcher, "hooks": [hookEntry]]]
                } else {
                    entryConfig = [["hooks": [hookEntry]]]
                }
            }

            // Strip any stale VibeHub entries (e.g. socket path changed across
            // builds) without disturbing user-owned hooks that happen to share
            // the same matcher entry.
            let existingEvent = hooks[event.name] as? [[String: Any]] ?? []
            let cleanedEvent = existingEvent.compactMap { removingVibehubHooks(from: $0) }
            hooks[event.name] = cleanedEvent + entryConfig
        }

        json["hooks"] = hooks

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: settingsURL)
        }
    }

    static func removeVibehubFromSettings(at settingsURL: URL, useFlatSchema _: Bool) {
        guard let data = try? Data(contentsOf: settingsURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            if let entries = value as? [[String: Any]] {
                let cleaned = entries.compactMap { removingVibehubHooks(from: $0) }
                if cleaned.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = cleaned
                }
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        if let out = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? out.write(to: settingsURL)
        }
    }

    /// Remove VibeHub-owned hooks from a single settings entry while
    /// preserving any unrelated hooks the user added to the same matcher.
    /// Returns `nil` if the entry becomes empty (caller drops it entirely).
    private static func removingVibehubHooks(from entry: [String: Any]) -> [String: Any]? {
        guard var entryHooks = entry["hooks"] as? [[String: Any]] else {
            return entry
        }
        entryHooks.removeAll { hook in
            let cmd = hook["command"] as? String ?? ""
            return cmd.contains("vibehub-state.py")
        }
        guard !entryHooks.isEmpty else { return nil }
        var updated = entry
        updated["hooks"] = entryHooks
        return updated
    }

    static func settingsContainsVibehub(at settingsURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
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

    // MARK: - TOML feature toggle

    /// Ensure `<section>.<key> = true` is set in the given TOML file.
    /// Used by Codex to flip `[features] codex_hooks = true`.
    static func applyTOMLFeatureToggle(at configURL: URL, section: String, key: String) {
        var contents = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""

        let alreadyOnPattern = #"(?m)^\s*\#(key)\s*=\s*true"#
        if contents.range(of: alreadyOnPattern, options: .regularExpression) != nil {
            return
        }

        let falsePattern = #"(?m)^\s*\#(key)\s*=\s*false"#
        if contents.range(of: falsePattern, options: .regularExpression) != nil {
            contents = contents.replacingOccurrences(
                of: falsePattern,
                with: "\(key) = true",
                options: .regularExpression
            )
            try? contents.write(to: configURL, atomically: true, encoding: .utf8)
            return
        }

        var lines = contents.components(separatedBy: "\n")
        if let idx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[\(section)]" }) {
            lines.insert("\(key) = true", at: idx + 1)
        } else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append("[\(section)]")
            lines.append("\(key) = true")
        }
        try? lines.joined(separator: "\n").write(to: configURL, atomically: true, encoding: .utf8)
    }
}
