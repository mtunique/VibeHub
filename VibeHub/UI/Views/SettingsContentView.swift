//
//  SettingsContentView.swift
//  VibeHub
//
//  Standalone settings window with native macOS sidebar + Form layout
//

import ApplicationServices
import Combine
import ServiceManagement
import SwiftUI

// MARK: - Settings Section

private enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance
    case notifications
    case remote
    case system
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return L10n.settingsAppearance
        case .notifications: return L10n.settingsNotifications
        case .remote: return L10n.remote
        case .system: return L10n.settingsSystem
        case .about: return L10n.settingsAbout
        }
    }

    var icon: String {
        switch self {
        case .appearance: return "paintbrush.fill"
        case .notifications: return "bell.badge.fill"
        case .remote: return "network"
        case .system: return "gearshape.fill"
        case .about: return "info.circle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .appearance: return .purple
        case .notifications: return .red
        case .remote: return .blue
        case .system: return .gray
        case .about: return .blue
        }
    }
}

/// macOS System Settings style icon: white SF Symbol on a colored rounded-rect background
private struct SettingsIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color)
            )
    }
}

// MARK: - Main View

struct SettingsContentView: View {
    @State private var selectedSection: SettingsSection? = .appearance

    private var mainSections: [SettingsSection] {
        [.appearance, .notifications, .remote, .system]
    }

    private var bottomSections: [SettingsSection] {
        [.about]
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $selectedSection) {
                Section {
                    ForEach(mainSections) { section in
                        sidebarRow(section)
                    }
                }

                Section {
                    ForEach(bottomSections) { section in
                        sidebarRow(section)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(200)
            .toolbar(removing: .sidebarToggle)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label {
                        Text(L10n.quit)
                    } icon: {
                        SettingsIcon(systemName: "power", color: .red)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } detail: {
            if let section = selectedSection {
                sectionDetail(section)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .navigationSplitViewColumnWidth(530)
            }
        }
        .navigationSplitViewColumnWidth(730)
        .navigationSplitViewStyle(.balanced)
    }

    private func sidebarRow(_ section: SettingsSection) -> some View {
        Label {
            Text(section.title)
        } icon: {
            SettingsIcon(systemName: section.icon, color: section.iconColor)
        }
        .padding(.vertical, 2)
        .tag(section)
    }

    @ViewBuilder
    private func sectionDetail(_ section: SettingsSection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(section.title)
                    .font(.title)
                    .fontWeight(.bold)
                    .padding(.horizontal, 20)
                    .padding(.top, -4)
                    .padding(.bottom, 12)

                sectionContent(section)
            }
        }
    }

    @ViewBuilder
    private func sectionContent(_ section: SettingsSection) -> some View {
        switch section {
        case .appearance:
            AppearanceSection()
        case .notifications:
            NotificationsSection()
        case .remote:
            RemoteSection()
        case .system:
            SystemSection()
        case .about:
            AboutSection()
        }
    }
}

// MARK: - Appearance Section

private struct AppearanceSection: View {
    @State private var displayMode: DisplayMode = AppSettings.displayMode
    @State private var menuBarShowDetail: Bool = AppSettings.menuBarShowDetail
    @State private var sound: NotificationSound = AppSettings.notificationSound

    var body: some View {
        Form {
            Section(L10n.displayModeLabel) {
                Picker(L10n.displayModeLabel, selection: $displayMode) {
                    Text(L10n.displayModeAuto).tag(DisplayMode.auto)
                    Text(L10n.displayModeNotch).tag(DisplayMode.notch)
                    Text(L10n.displayModeMenuBar).tag(DisplayMode.menuBar)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: displayMode) { _, newValue in
                    AppSettings.displayMode = newValue
                    NotificationCenter.default.post(name: .displayModeChanged, object: nil)
                }

                if WindowManager.resolveMode(displayMode) == .menuBar {
                    Toggle(L10n.menuBarShowDetail, isOn: $menuBarShowDetail)
                        .onChange(of: menuBarShowDetail) { _, newValue in
                            AppSettings.menuBarShowDetail = newValue
                            NotificationCenter.default.post(name: .displayModeChanged, object: nil)
                        }
                }
            }

            Section(L10n.notificationSound) {
                Picker(L10n.notificationSound, selection: $sound) {
                    ForEach(NotificationSound.allCases, id: \.self) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .labelsHidden()
                .onChange(of: sound) { _, newValue in
                    AppSettings.notificationSound = newValue
                    if let name = newValue.soundName {
                        NSSound(named: name)?.play()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Notifications Section

private struct NotificationsSection: View {
    @State private var notifyCompletion: NotifyMode = AppSettings.notifyCompletion
    @State private var notifyApproval: NotifyMode = AppSettings.notifyApproval

    var body: some View {
        Form {
            Section {
                Picker(L10n.notifyCompletion, selection: $notifyCompletion) {
                    Text(L10n.notifyNever).tag(NotifyMode.never)
                    Text(L10n.notifyBackgroundOnly).tag(NotifyMode.backgroundOnly)
                    Text(L10n.notifyAlways).tag(NotifyMode.always)
                }
                .onChange(of: notifyCompletion) { _, newValue in
                    AppSettings.notifyCompletion = newValue
                }

                Picker(L10n.notifyApproval, selection: $notifyApproval) {
                    Text(L10n.notifyNever).tag(NotifyMode.never)
                    Text(L10n.notifyBackgroundOnly).tag(NotifyMode.backgroundOnly)
                    Text(L10n.notifyAlways).tag(NotifyMode.always)
                }
                .onChange(of: notifyApproval) { _, newValue in
                    AppSettings.notifyApproval = newValue
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Remote Section

private struct RemoteSection: View {
    var body: some View {
        RemoteHostsView()
    }
}

// MARK: - System Section

private struct SystemSection: View {
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var hooksInstalled: Bool = HookInstaller.installedSubject.value
    @State private var accessibilityEnabled: Bool = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section {
                Toggle(L10n.launchAtLogin, isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = !newValue
                        }
                    }

                Toggle(L10n.hooks, isOn: $hooksInstalled)
                    .onChange(of: hooksInstalled) { _, newValue in
                        if newValue {
                            HookInstaller.installIfNeeded()
                        } else {
                            HookInstaller.uninstall()
                        }
                    }
                    .onReceive(HookInstaller.installedSubject.receive(on: DispatchQueue.main)) {
                        hooksInstalled = $0
                    }
            }

            Section {
                HStack {
                    Text(L10n.accessibility)
                    Spacer()
                    if accessibilityEnabled {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button(L10n.enable) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityEnabled = AXIsProcessTrusted()
        }
    }
}

// MARK: - About Section

private struct AboutSection: View {
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    if let appIcon = NSImage(named: "AppIcon") {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 11))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Vibe Hub").font(.headline)
                        Text(appVersion).font(.subheadline).foregroundColor(.secondary)
                    }
                    Spacer()
                    #if !APP_STORE
                    SettingsUpdateButton()
                    #endif
                }
            }

            Section {
                Link(destination: URL(string: "https://github.com/mtunique/VibeHub")!) {
                    Label(L10n.starOnGitHub, systemImage: "star")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Settings Update Button

#if !APP_STORE
private struct SettingsUpdateButton: View {
    @ObservedObject private var updateManager = UpdateManager.shared

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 6) {
                switch updateManager.state {
                case .checking, .installing:
                    ProgressView()
                        .controlSize(.small)
                case .downloading(let progress):
                    ProgressView(value: progress)
                        .frame(width: 40)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                case .extracting(let progress):
                    ProgressView(value: progress)
                        .frame(width: 40)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                default:
                    Text(label)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!isInteractive)
        .tint(tintColor)
    }

    private var label: String {
        switch updateManager.state {
        case .idle:
            return L10n.checkForUpdates
        case .upToDate:
            return L10n.upToDate
        case .found(let version, _):
            return "\(L10n.downloadUpdate) v\(version)"
        case .readyToInstall:
            return L10n.installAndRelaunch
        case .error:
            return L10n.retry
        default:
            return ""
        }
    }

    private var tintColor: Color? {
        switch updateManager.state {
        case .found, .readyToInstall:
            return .accentColor
        case .error:
            return .red
        default:
            return nil
        }
    }

    private var isInteractive: Bool {
        switch updateManager.state {
        case .idle, .upToDate, .found, .readyToInstall, .error:
            return true
        default:
            return false
        }
    }

    private func handleTap() {
        switch updateManager.state {
        case .idle, .upToDate, .error:
            updateManager.checkForUpdates()
        case .found:
            updateManager.downloadAndInstall()
        case .readyToInstall:
            updateManager.installAndRelaunch()
        default:
            break
        }
    }
}
#endif
