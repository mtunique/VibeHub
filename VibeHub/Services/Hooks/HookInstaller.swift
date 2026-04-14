//
//  HookInstaller.swift
//  VibeHub
//
//  Thin wrapper that delegates all install / uninstall work to
//  `CLIInstaller`. Exists primarily to:
//  - publish `installedSubject` for the settings UI to observe
//  - watch `~/.claude/settings.json` for external edits
//  - provide the App-Store-specific bookmark + security-scope shims
//
//  The actual hook-schema writing lives in CLIInstaller.
//

import Combine
import Foundation
import os.log

struct HookInstaller {

    // MARK: - Settings file watcher

    private static let watchLogger = Logger(subsystem: "com.vibehub", category: "HookInstaller")
    private static var settingsSource: DispatchSourceFileSystemObject?
    private static var settingsFd: Int32 = -1

    /// Observable hook-installed state. UI binds to this instead of polling.
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
        static let claudeDirBookmarkKey = "ci.bookmark.claudeDir"
        static let opencodeDirBookmarkKey = "ci.bookmark.opencodeDir"
    }
#endif

    /// Install hook scripts and plugins for every enabled CLI on app launch.
    static func installIfNeeded() {
#if APP_STORE
        if let homeDir = resolveBookmark(key: Defaults.claudeDirBookmarkKey) {
            _ = withSecurityScope(url: homeDir) {
                CLIInstaller.installSharedScript()
                for config in CLIConfig.all {
                    CLIInstaller.installLocal(config: config, homeDir: homeDir)
                }
            }
        }
        return
#else
        CLIInstaller.installAllLocal()
        installedSubject.send(CLIInstaller.isAnyInstalled())
#endif
    }

    /// Check if hooks are currently installed for Claude or any other CLI.
    static func isInstalled() -> Bool {
#if APP_STORE
        guard let homeDir = resolveBookmark(key: Defaults.claudeDirBookmarkKey) else {
            return false
        }
        return withSecurityScope(url: homeDir) {
            for config in CLIConfig.all {
                if CLIInstaller.isInstalled(config: config, homeDir: homeDir) {
                    return true
                }
            }
            return false
        } ?? false
#else
        return CLIInstaller.isAnyInstalled()
#endif
    }

    /// Per-CLI install status for the settings page. Handles the sandbox
    /// bookmark dance in App Store builds so callers don't have to.
    static func perCLIStatus() -> [CLIInstaller.InstallStatus] {
#if APP_STORE
        guard let homeDir = resolveBookmark(key: Defaults.claudeDirBookmarkKey) else {
            // No bookmark yet — report everything as "not installed, config unknown".
            return CLIConfig.all.map { cfg in
                CLIInstaller.InstallStatus(
                    source: cfg.source,
                    configExists: false,
                    hookInstalled: false
                )
            }
        }
        return withSecurityScope(url: homeDir) {
            CLIConfig.all.map { cfg in
                CLIInstaller.InstallStatus(
                    source: cfg.source,
                    configExists: CLIInstaller.configDirExists(config: cfg, homeDir: homeDir),
                    hookInstalled: CLIInstaller.isInstalled(config: cfg, homeDir: homeDir)
                )
            }
        } ?? []
#else
        return CLIInstaller.perCLIStatus()
#endif
    }

    /// Uninstall hooks for every CLI.
    static func uninstall() {
#if APP_STORE
        _ = uninstallAppStore()
        return
#else
        CLIInstaller.uninstallAllLocal()
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
    /// Kept for back-compat — new code should use `CLIInstaller.installLocal`.
    static func installAppStore(claudeDir: URL) -> Bool {
        CLIInstaller.installSharedScript()
        CLIInstaller.installClaudeStyle(config: .claude, configDir: claudeDir)
        installedSubject.send(true)
        return true
    }

    /// Installs OpenCode plugin into the provided OpenCode config dir.
    /// Caller must have an active security scope for opencodeDir.
    static func installOpenCodeAppStore(opencodeDir: URL) -> Bool {
        CLIInstaller.installOpenCodePlugin(config: .opencode, configDir: opencodeDir)
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
            _ = withSecurityScope(url: homeDir) {
                for config in CLIConfig.all {
                    CLIInstaller.uninstallLocal(config: config, homeDir: homeDir)
                }
            }
        } else {
            ok = false
        }
        return ok
    }

    // MARK: - Helpers

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

    // MARK: - Shared script (back-compat shims)
    //
    // A handful of call sites still reference these symbols via HookInstaller.
    // They all forward to CLIInstaller.

    static var sharedScriptURL: URL { CLIInstaller.sharedScriptURL }

    static func installSharedScript() {
        CLIInstaller.installSharedScript()
    }

    static func ensureSymlink(at link: URL, target: URL) {
        CLIInstaller.ensureSymlink(at: link, target: target)
    }

    static func detectPython() -> String {
        CLIInstaller.detectPython()
    }
}
