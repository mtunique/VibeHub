//
//  TmuxPathFinder.swift
//  VibeHub
//
//  Finds tmux executable path
//

import Foundation

/// Finds and caches the tmux executable path
actor TmuxPathFinder {
    static let shared = TmuxPathFinder()

    /// Path reported by the hook (from `which tmux` in the session's environment)
    private var hookReportedPath: String?

    private init() {}

    /// Set the tmux path as reported by the hook
    func setHookReportedPath(_ path: String) {
        hookReportedPath = path
    }

    /// Get the path to tmux executable
    func getTmuxPath() -> String? {
        #if APP_STORE
        return nil  // Sandbox cannot execute external tmux binary
        #else
        if let path = hookReportedPath,
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
        #endif
    }

    /// Check if tmux is available
    func isTmuxAvailable() -> Bool {
        getTmuxPath() != nil
    }
}
