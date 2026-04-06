//
//  SettingsContentView.swift
//  VibeHub
//
//  Standalone settings window with native macOS sidebar + Form layout
//

import ApplicationServices
import ServiceManagement
import SwiftUI

// MARK: - Settings Section

private enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance
    case notifications
    case remote
    case system
    #if !APP_STORE
    case license
    #endif
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return L10n.settingsAppearance
        case .notifications: return L10n.settingsNotifications
        case .remote: return L10n.remote
        case .system: return L10n.settingsSystem
        #if !APP_STORE
        case .license: return L10n.license
        #endif
        case .about: return L10n.settingsAbout
        }
    }

    var icon: String {
        switch self {
        case .appearance: return "paintbrush.fill"
        case .notifications: return "bell.badge.fill"
        case .remote: return "network"
        case .system: return "gearshape.fill"
        #if !APP_STORE
        case .license: return "key.fill"
        #endif
        case .about: return "info.circle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .appearance: return .purple
        case .notifications: return .red
        case .remote: return .blue
        case .system: return .gray
        #if !APP_STORE
        case .license: return .orange
        #endif
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
        var sections: [SettingsSection] = []
        #if !APP_STORE
        sections.append(.license)
        #endif
        sections.append(.about)
        return sections
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
        .onReceive(NotificationCenter.default.publisher(for: .settingsNavigateToLicense)) { _ in
            #if !APP_STORE
            selectedSection = .license
            #endif
        }
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
        #if !APP_STORE
        case .license:
            LicenseSection()
        #endif
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
    @State private var hooksInstalled: Bool = HookInstaller.isInstalled()
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
                        hooksInstalled = HookInstaller.isInstalled()
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

// MARK: - License Section

#if !APP_STORE
private struct LicenseSection: View {
    @ObservedObject private var licenseManager = LicenseManager.shared
    @State private var licenseKeyInput = ""
    @State private var isActivating = false
    @State private var showConfirmDeactivate = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(L10n.license)
                    Spacer()
                    statusBadge
                }

                if licenseManager.status == .activated {
                    LabeledContent(L10n.licenseKeyPlaceholder) {
                        Text(licenseManager.maskedKey)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    LabeledContent(L10n.licenseDevices) {
                        Text(L10n.licenseDeviceCount(licenseManager.activationCount, licenseManager.activationLimit))
                            .foregroundColor(.secondary)
                    }
                }
            }

            if licenseManager.status != .activated {
                Section(L10n.licenseActivate) {
                    HStack(spacing: 8) {
                        TextField(L10n.licenseKeyPlaceholder, text: $licenseKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .disabled(isActivating)
                            .onSubmit { doActivate() }

                        Button {
                            doActivate()
                        } label: {
                            if isActivating {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(L10n.licenseActivate)
                            }
                        }
                        .disabled(licenseKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isActivating)
                    }

                    if let err = licenseManager.errorMessage {
                        Text(err).foregroundColor(.red).font(.caption)
                    }

                    Link(destination: URL(string: LemonSqueezyAPIClient.checkoutURL)!) {
                        Label(L10n.licensePurchase, systemImage: "cart")
                    }
                }
            }

            if licenseManager.status == .activated {
                Section {
                    if showConfirmDeactivate {
                        HStack {
                            Text(L10n.licenseDeactivateDevice)
                                .foregroundColor(.red)
                            Spacer()
                            Button(role: .destructive) {
                                Task {
                                    await licenseManager.deactivateThisDevice()
                                    showConfirmDeactivate = false
                                }
                            } label: {
                                Text(L10n.licenseDeactivateDevice)
                            }
                        }
                    } else {
                        Button(L10n.licenseDeactivateDevice) {
                            showConfirmDeactivate = true
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch licenseManager.status {
        case .activated:
            Label(L10n.licenseActivated, systemImage: "checkmark.circle.fill").foregroundColor(.green)
        case .trial:
            Label(L10n.trialTimeRemaining(hours: licenseManager.trialHoursRemaining), systemImage: "clock").foregroundColor(.orange)
        case .locked:
            Label(L10n.trialExpiredTitle, systemImage: "exclamationmark.triangle.fill").foregroundColor(.red)
        case .validating:
            ProgressView().controlSize(.small)
        }
    }

    private func doActivate() {
        let trimmed = licenseKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isActivating else { return }
        isActivating = true
        Task {
            await licenseManager.activate(key: trimmed)
            isActivating = false
            if licenseManager.status == .activated { licenseKeyInput = "" }
        }
    }
}
#endif

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
                }
            }

            Section {
                #if !APP_STORE
                Button(L10n.checkForUpdates) {
                    UpdateManager.shared.checkForUpdates()
                }
                #endif

                Link(destination: URL(string: "https://github.com/mtunique/vibehub")!) {
                    Label(L10n.starOnGitHub, systemImage: "star")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
