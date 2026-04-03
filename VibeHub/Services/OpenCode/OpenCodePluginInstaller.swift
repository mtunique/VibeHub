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

        let configFile = opencodeDir.appendingPathComponent("opencode.json")
        guard FileManager.default.fileExists(atPath: configFile.path) else {
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
                // Best effort; don't fail app launch
                return
            }
        } else {
            // If the resource isn't bundled, skip silently.
            return
        }

        updateOpenCodeConfig(configFile: configFile, pluginFile: pluginFile)
    }

    private static func updateOpenCodeConfig(configFile: URL, pluginFile: URL) {
        guard let data = try? Data(contentsOf: configFile),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
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
            return
        }

        try? out.write(to: configFile)
    }
}
