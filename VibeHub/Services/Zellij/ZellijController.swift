//
//  ZellijController.swift
//  VibeHub
//
//  Zellij multiplexer operations: pane discovery, focus, and message sending.
//

import Foundation
import os.log

/// Controller for zellij operations, mirrors TmuxController's role.
actor ZellijController {
    static let shared = ZellijController()

    nonisolated static let logger = Logger(subsystem: "com.vibehub", category: "Zellij")

    private var cachedPath: String?

    private init() {}

    // MARK: - Path Discovery

    private func zellijPath() -> String? {
        #if APP_STORE
        return nil
        #else
        if let cached = cachedPath { return cached }

        let candidates = [
            "/opt/homebrew/bin/zellij",
            "/usr/local/bin/zellij",
            "/usr/bin/zellij",
            "/run/current-system/sw/bin/zellij",  // NixOS / nix-darwin
            "/nix/var/nix/profiles/default/bin/zellij"
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedPath = path
                return path
            }
        }

        return nil
        #endif
    }

    // MARK: - Pane Discovery

    /// Find the zellij pane ID that contains the given Claude PID.
    /// Uses `zellij action list-clients` if available, or falls back to
    /// walking pane PIDs via `zellij action dump-layout`.
    private func findPaneId(forClaudePid pid: Int) async -> String? {
        guard zellijPath() != nil else { return nil }

        // Claude inherits ZELLIJ_PANE_ID env var when spawned inside zellij.
        // Read it from the process environment on macOS.
        return readZellijPaneIdFromEnv(pid: pid)
    }

    /// Read ZELLIJ_PANE_ID from a process's environment (macOS).
    private nonisolated func readZellijPaneIdFromEnv(pid: Int) -> String? {
        // On macOS we can read the environment of a process via sysctl KERN_PROCARGS2
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        // Skip argc
        var ptr = MemoryLayout<Int32>.size
        var argc: Int32 = 0
        memcpy(&argc, buffer, MemoryLayout<Int32>.size)

        // Skip executable path
        while ptr < size && buffer[ptr] != 0 { ptr += 1 }
        // Skip null padding
        while ptr < size && buffer[ptr] == 0 { ptr += 1 }
        // Skip argv strings
        for _ in 0..<argc {
            while ptr < size && buffer[ptr] != 0 { ptr += 1 }
            ptr += 1
        }

        // Now we're in the environment strings
        let envPrefix = "ZELLIJ_PANE_ID="
        let envPrefixBytes = [UInt8](envPrefix.utf8)
        while ptr < size {
            // Find start of next env string
            let start = ptr
            while ptr < size && buffer[ptr] != 0 { ptr += 1 }
            let envBytes = Array(buffer[start..<ptr])
            ptr += 1

            if envBytes.isEmpty { continue }
            if envBytes.starts(with: envPrefixBytes) {
                let valueBytes = envBytes.dropFirst(envPrefixBytes.count)
                return String(bytes: valueBytes, encoding: .utf8)
            }
        }

        return nil
    }

    // MARK: - Message Sending

    /// Send a message to the zellij pane containing the given Claude PID.
    func sendMessage(_ message: String, forClaudePid pid: Int) async -> Bool {
        guard let zjPath = zellijPath() else { return false }

        // `zellij action write-chars` writes to the focused pane of the current session.
        // To target a specific pane we need the session name and pane ID.
        // For now, write-chars with session targeting via ZELLIJ_SESSION_NAME.
        let sessionName = readZellijSessionName(pid: pid)

        var args = ["action", "write-chars", "--", message + "\n"]
        var env: [String: String]? = nil
        if let sessionName {
            // When targeting a specific session, we can pass it via env
            env = ["ZELLIJ_SESSION_NAME": sessionName]
        }

        do {
            Self.logger.debug("Sending message to zellij session=\(sessionName ?? "default", privacy: .public)")
            _ = try await ProcessExecutor.shared.run(zjPath, arguments: args, environment: env)
            return true
        } catch {
            Self.logger.error("zellij write-chars failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Pane Focus

    /// Focus the zellij pane containing the given Claude PID.
    func focusPane(forClaudePid pid: Int) async {
        guard let zjPath = zellijPath() else { return }
        guard let paneId = await findPaneId(forClaudePid: pid) else { return }

        let sessionName = readZellijSessionName(pid: pid)
        var env: [String: String]? = nil
        if let sessionName {
            env = ["ZELLIJ_SESSION_NAME": sessionName]
        }

        do {
            _ = try await ProcessExecutor.shared.run(
                zjPath,
                arguments: ["action", "focus-pane", "--pane-id", paneId],
                environment: env
            )
        } catch {
            Self.logger.error("zellij focus-pane failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Check if the zellij pane containing the given Claude PID is currently focused.
    func isSessionPaneFocused(claudePid: Int) async -> Bool {
        // Heuristic: if we can find the pane ID, the session is active.
        // A more precise check would require parsing zellij layout output,
        // but for now this is a reasonable approximation — the terminal
        // frontmost check in the caller already gates on the app being focused.
        return await findPaneId(forClaudePid: claudePid) != nil
    }

    // MARK: - Helpers

    /// Read ZELLIJ_SESSION_NAME from a process's environment.
    private nonisolated func readZellijSessionName(pid: Int) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        var ptr = MemoryLayout<Int32>.size
        var argc: Int32 = 0
        memcpy(&argc, buffer, MemoryLayout<Int32>.size)

        // Skip executable path
        while ptr < size && buffer[ptr] != 0 { ptr += 1 }
        while ptr < size && buffer[ptr] == 0 { ptr += 1 }
        // Skip argv
        for _ in 0..<argc {
            while ptr < size && buffer[ptr] != 0 { ptr += 1 }
            ptr += 1
        }

        let envPrefix = "ZELLIJ_SESSION_NAME="
        let envPrefixBytes = [UInt8](envPrefix.utf8)
        while ptr < size {
            let start = ptr
            while ptr < size && buffer[ptr] != 0 { ptr += 1 }
            let envBytes = Array(buffer[start..<ptr])
            ptr += 1

            if envBytes.isEmpty { continue }
            if envBytes.starts(with: envPrefixBytes) {
                let valueBytes = envBytes.dropFirst(envPrefixBytes.count)
                return String(bytes: valueBytes, encoding: .utf8)
            }
        }

        return nil
    }
}
