//
//  OpenCodePluginInstaller.swift
//  VibeHub
//
//  Installs an OpenCode plugin that forwards events to Claude Island.
//

import Foundation

struct OpenCodePluginInstaller {

    static func installIfNeeded() {
        let home = FileManager.default.homeDirectoryForCurrentUser

        // OpenCode uses XDG config by default.
        let opencodeDir = home
            .appendingPathComponent(".config")
            .appendingPathComponent("opencode")

        // Only install if the user has OpenCode config dir (i.e. has run opencode before).
        // Plugins in ~/.config/opencode/plugins/ are auto-discovered — no opencode.json registration needed.
        guard FileManager.default.fileExists(atPath: opencodeDir.path) else {
            return
        }

        let pluginsDir = opencodeDir.appendingPathComponent("plugins")
        let pluginFile = pluginsDir.appendingPathComponent("vibehub.js")

        try? FileManager.default.createDirectory(
            at: pluginsDir,
            withIntermediateDirectories: true
        )

        // Copy JS plugin from app bundle
        if let bundled = Bundle.main.url(forResource: "vibehub-opencode", withExtension: "js") {
            try? FileManager.default.removeItem(at: pluginFile)
            do {
                try FileManager.default.copyItem(at: bundled, to: pluginFile)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: pluginFile.path
                )
            } catch {
                return
            }
        } else {
            return
        }

        // Write sidecar socket path so the plugin knows where to connect.
        let socketFile = pluginsDir.appendingPathComponent("vibehub.socket")
        let socketPath = HookSocketPaths.socketPath + "\n"
        try? socketPath.data(using: .utf8)?.write(to: socketFile, options: [.atomic])
    }
}
