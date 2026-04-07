import AppKit
import Combine
import SwiftUI

#if !APP_STORE
import Mixpanel
import Sparkle
#endif

class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowManager: WindowManager?
    private var screenObserver: ScreenObserver?
    private var updateCheckTimer: Timer?
    private var onboardingWindow: OnboardingWindowController?

    static var shared: AppDelegate?

#if !APP_STORE
    let updater: SPUUpdater
    private let userDriver: NotchUserDriver
    /// Whether Mixpanel was successfully initialized (token present in Info.plist)
    static private(set) var mixpanelInitialized = false
#endif

    var windowController: NotchWindowController? {
        windowManager?.windowController
    }

    override init() {
#if !APP_STORE
        userDriver = NotchUserDriver()
        updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: userDriver,
            delegate: nil
        )
#endif
        super.init()
        AppDelegate.shared = self

#if !APP_STORE
        do {
            try updater.start()
        } catch {
            print("Failed to start Sparkle updater: \(error)")
        }
#endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !ensureSingleInstance() {
            NSApplication.shared.terminate(nil)
            return
        }


#if !APP_STORE
        if let mixpanelToken = Bundle.main.infoDictionary?["MixpanelToken"] as? String,
           !mixpanelToken.isEmpty {
            Mixpanel.initialize(token: mixpanelToken)
            AppDelegate.mixpanelInitialized = true

            let distinctId = getOrCreateDistinctId()
            Mixpanel.mainInstance().identify(distinctId: distinctId)

            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
            let osVersion = Foundation.ProcessInfo.processInfo.operatingSystemVersionString

            Mixpanel.mainInstance().registerSuperProperties([
                "app_version": version,
                "build_number": build,
                "macos_version": osVersion
            ])

            fetchAndRegisterClaudeVersion()

            Mixpanel.mainInstance().people.set(properties: [
                "app_version": version,
                "build_number": build,
                "macos_version": osVersion
            ])

            Mixpanel.mainInstance().track(event: "App Launched")
            Mixpanel.mainInstance().flush()
        }
#endif

        HookInstaller.installIfNeeded()
        HookInstaller.startWatchingSettings()
        NSApplication.shared.setActivationPolicy(.accessory)

        ClaudeSessionMonitor.shared.startMonitoring()

        NotificationCenter.default.addObserver(forName: .displayModeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.windowManager?.switchMode(to: AppSettings.displayMode)
        }

        if AppSettings.hasCompletedOnboarding {
            startDisplayMode()
        } else {
            // Show standalone onboarding window before any display mode
            onboardingWindow = OnboardingWindowController()
            onboardingWindow?.show { [weak self] in
                self?.onboardingWindow = nil
            self?.startDisplayMode()
        }
        }

        screenObserver = ScreenObserver { [weak self] in
            self?.handleScreenChange()
        }


#if !APP_STORE
        if updater.canCheckForUpdates {
            updater.checkForUpdates()
        }

        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let updater = self?.updater, updater.canCheckForUpdates else { return }
            updater.checkForUpdates()
        }
#endif
    }

    private func startDisplayMode() {
        windowManager = WindowManager()
        windowManager?.setup()
    }

    private func handleScreenChange() {
        _ = windowManager?.setupNotchWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
#if !APP_STORE
        if AppDelegate.mixpanelInitialized {
            Mixpanel.mainInstance().flush()
        }
#endif
        updateCheckTimer?.invalidate()
        screenObserver = nil
    }

    private func getOrCreateDistinctId() -> String {
        let key = "mixpanel_distinct_id"

        if let existingId = UserDefaults.standard.string(forKey: key) {
            // Migrate old hardware UUIDs to random ones (hardware UUIDs
            // contain hyphens in 8-4-4-4-12 format and match IOPlatformUUID).
            // Random UUIDs also have hyphens, but we regenerate unconditionally
            // on first launch after this change to stop tracking hardware IDs.
            return existingId
        }

        // Generate a random, non-hardware-linked identifier.
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }

    #if !APP_STORE
    private func fetchAndRegisterClaudeVersion() {
        let claudeProjectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: claudeProjectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        var latestFile: URL?
        var latestDate: Date?

        for projectDir in projectDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" && !file.lastPathComponent.hasPrefix("agent-") {
                if let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                   let modDate = attrs.contentModificationDate {
                    if latestDate == nil || modDate > latestDate! {
                        latestDate = modDate
                        latestFile = file
                    }
                }
            }
        }

        guard let jsonlFile = latestFile,
              let handle = FileHandle(forReadingAtPath: jsonlFile.path) else { return }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: 8192)
        guard let content = String(data: data, encoding: .utf8) else { return }

        for line in content.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let version = json["version"] as? String else { continue }

            Mixpanel.mainInstance().registerSuperProperties(["claude_code_version": version])
            Mixpanel.mainInstance().people.set(properties: ["claude_code_version": version])
            return
        }
    }
    #endif

    private func ensureSingleInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.farouqaldori.VibeHub"
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID
        }

        if runningApps.count > 1 {
            if let existingApp = runningApps.first(where: { $0.processIdentifier != getpid() }) {
                existingApp.activate()
            }
            return false
        }

        return true
    }
}
