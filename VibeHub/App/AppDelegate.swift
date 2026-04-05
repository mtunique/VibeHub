import AppKit
import Clibssh
import Combine
import IOKit
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
    #if !APP_STORE
    private var licenseCancellables = Set<AnyCancellable>()
    #endif

    static var shared: AppDelegate?

#if !APP_STORE
    let updater: SPUUpdater
    private let userDriver: NotchUserDriver
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
        // libssh + mbedTLS must be initialized before any SSH session.
        vibehub_ssh_global_init()

        if !ensureSingleInstance() {
            NSApplication.shared.terminate(nil)
            return
        }


#if !APP_STORE
        Mixpanel.initialize(token: "49814c1436104ed108f3fc4735228496")

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
#endif

        HookInstaller.installIfNeeded()
#if !APP_STORE
        OpenCodePluginInstaller.installIfNeeded()
#endif
        NSApplication.shared.setActivationPolicy(.accessory)

        ClaudeSessionMonitor.shared.startMonitoring()

        NotificationCenter.default.addObserver(forName: .displayModeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.windowManager?.switchMode(to: AppSettings.displayMode)
        }

        if AppSettings.hasCompletedOnboarding {
            startDisplayMode()
            #if !APP_STORE
            validateLicenseOnStartup()
            #endif
        } else {
            // Show standalone onboarding window before any display mode
            onboardingWindow = OnboardingWindowController()
            onboardingWindow?.show { [weak self] in
                self?.onboardingWindow = nil
                self?.startDisplayMode()
                #if !APP_STORE
                self?.validateLicenseOnStartup()
                #endif
            }
        }

        RemoteManager.shared.startup()

        #if !APP_STORE
        // Watch for license status changes to lock/unlock UI
        LicenseManager.shared.$status
            .dropFirst()  // skip initial .locked value before validateOnStartup runs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newStatus in
                guard let vm = self?.windowController?.viewModel else { return }
                switch newStatus {
                case .locked:
                    vm.notchOpen(reason: .boot)
                    vm.contentType = .license
                case .activated, .trial:
                    if case .license = vm.contentType {
                        vm.contentType = .instances
                        vm.notchClose()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            vm.performBootAnimation()
                        }
                    }
                case .validating:
                    break
                }
            }
            .store(in: &licenseCancellables)
        #endif

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

    #if !APP_STORE
    private func validateLicenseOnStartup() {
        Task { @MainActor in
            let isValid = await LicenseManager.shared.validateOnStartup()
            if !isValid {
                if let vm = windowController?.viewModel {
                    vm.notchOpen(reason: .boot)
                    vm.contentType = .license
                }
            }
        }
    }
    #endif

    private func handleScreenChange() {
        _ = windowManager?.setupNotchWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
#if !APP_STORE
        Mixpanel.mainInstance().flush()
#endif
        updateCheckTimer?.invalidate()
        screenObserver = nil
    }

    private func getOrCreateDistinctId() -> String {
        let key = "mixpanel_distinct_id"

        if let existingId = UserDefaults.standard.string(forKey: key) {
            return existingId
        }

        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }

        if let uuid = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String {
            UserDefaults.standard.set(uuid, forKey: key)
            return uuid
        }

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
