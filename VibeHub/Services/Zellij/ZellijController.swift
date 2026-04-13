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

    // MARK: - Zellij Environment

    private func zellijEnv(session: SessionState) -> (zjPath: String, paneId: String, env: [String: String]?)? {
        guard let zjPath = zellijPath() else { return nil }
        guard let paneId = session.zellijPaneId else {
            Self.logger.error("No zellij pane ID for session pid=\(session.pid ?? -1, privacy: .public)")
            return nil
        }
        var env: [String: String]? = nil
        if let sessionName = session.zellijSession {
            env = ["ZELLIJ_SESSION_NAME": sessionName]
        }
        return (zjPath, paneId, env)
    }

    // MARK: - Message Sending

    /// Send a message to the zellij pane for the given session.
    func sendMessage(_ message: String, session: SessionState) async -> Bool {
        guard let zj = zellijEnv(session: session) else { return false }

        let args = ["action", "write-chars", "--pane-id", zj.paneId, "--", message + "\n"]

        do {
            Self.logger.debug("Sending message to zellij pane=\(zj.paneId, privacy: .public)")
            _ = try await ProcessExecutor.shared.run(zj.zjPath, arguments: args, environment: zj.env)
            return true
        } catch {
            Self.logger.error("zellij write-chars failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Pane Focus

    /// Focus the zellij pane for the given session.
    func focusPane(session: SessionState) async {
        guard let zj = zellijEnv(session: session) else { return }

        do {
            _ = try await ProcessExecutor.shared.run(
                zj.zjPath,
                arguments: ["action", "focus-pane", "--pane-id", zj.paneId],
                environment: zj.env
            )
        } catch {
            Self.logger.error("zellij focus-pane failed: \(error.localizedDescription, privacy: .public)")
        }
    }

}
