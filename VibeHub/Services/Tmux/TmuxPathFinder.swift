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

    private var cachedPath: String?

    private init() {}

    /// Get the path to tmux executable
    func getTmuxPath() -> String? {
        #if APP_STORE
        return nil  // Sandbox cannot execute external tmux binary
        #else
        if let cached = cachedPath {
            return cached
        }

        let possiblePaths = [
            "/opt/homebrew/bin/tmux",  // Apple Silicon Homebrew
            "/usr/local/bin/tmux",     // Intel Homebrew
            "/usr/bin/tmux",           // System
            "/bin/tmux"
        ]

        for path in possiblePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedPath = path
                return path
            }
        }

        return nil
        #endif
    }

    /// Check if tmux is available
    func isTmuxAvailable() -> Bool {
        getTmuxPath() != nil
    }
}
