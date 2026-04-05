//
//  SettingsContentView.swift
//  VibeHub
//
//  Standalone settings window content with sidebar navigation
//

import ApplicationServices
import ServiceManagement
import SwiftUI

// MARK: - Settings Section

private enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance
    case notifications
    case system
    #if !APP_STORE
    case license
    #endif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return L10n.settingsAppearance
        case .notifications: return L10n.settingsNotifications
        case .system: return L10n.settingsSystem
        #if !APP_STORE
        case .license: return L10n.license
        #endif
        }
    }

    var icon: String {
        switch self {
        case .appearance: return "paintbrush"
        case .notifications: return "bell"
        case .system: return "gearshape"
        #if !APP_STORE
        case .license: return "key"
        #endif
        }
    }
}

// MARK: - Main View

struct SettingsContentView: View {
    @State private var selectedSection: SettingsSection = .appearance

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases) { section in
                    sidebarButton(section)
                }
                Spacer()
            }
            .padding(8)
            .frame(width: 160)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))

            Divider()

            // Detail
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sectionDetail(selectedSection)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 580, minHeight: 380)
        .onReceive(NotificationCenter.default.publisher(for: .settingsNavigateToLicense)) { _ in
            #if !APP_STORE
            selectedSection = .license
            #endif
        }
    }

    // MARK: - Sidebar Button

    private func sidebarButton(_ section: SettingsSection) -> some View {
        Button {
            selectedSection = section
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 13))
                    .frame(width: 20)
                Text(section.title)
                    .font(.system(size: 13))
                Spacer()
            }
            .foregroundColor(selectedSection == section ? .white : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedSection == section ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail Content

    @ViewBuilder
    private func sectionDetail(_ section: SettingsSection) -> some View {
        switch section {
        case .appearance:
            AppearanceSection()
        case .notifications:
            NotificationsSection()
        case .system:
            SystemSection()
        #if !APP_STORE
        case .license:
            LicenseSection()
        #endif
        }
    }
}

// MARK: - Appearance Section

private struct AppearanceSection: View {
    @ObservedObject private var screenSelector = ScreenSelector.shared
    @ObservedObject private var soundSelector = SoundSelector.shared
    @State private var displayMode: DisplayMode = AppSettings.displayMode
    @State private var menuBarShowDetail: Bool = AppSettings.menuBarShowDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(L10n.settingsAppearance)

            settingsGroup {
                ScreenPickerRow(screenSelector: screenSelector)
                Divider()
                SoundPickerRow(soundSelector: soundSelector)
            }

            settingsGroup {
                DisplayModePicker(currentMode: $displayMode)
                if WindowManager.resolveMode(displayMode) == .menuBar {
                    Divider()
                    MenuToggleRow(
                        icon: "text.alignleft",
                        label: L10n.menuBarShowDetail,
                        isOn: menuBarShowDetail
                    ) {
                        menuBarShowDetail.toggle()
                        AppSettings.menuBarShowDetail = menuBarShowDetail
                        NotificationCenter.default.post(name: .displayModeChanged, object: nil)
                    }
                }
            }
        }
    }
}

// MARK: - Notifications Section

private struct NotificationsSection: View {
    @State private var notifyCompletion: NotifyMode = AppSettings.notifyCompletion
    @State private var notifyApproval: NotifyMode = AppSettings.notifyApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(L10n.settingsNotifications)

            settingsGroup {
                NotifyModePicker(
                    icon: "checkmark.circle",
                    label: L10n.notifyCompletion,
                    mode: $notifyCompletion
                ) { newMode in AppSettings.notifyCompletion = newMode }

                Divider()

                NotifyModePicker(
                    icon: "lock.shield",
                    label: L10n.notifyApproval,
                    mode: $notifyApproval
                ) { newMode in AppSettings.notifyApproval = newMode }
            }
        }
    }
}

// MARK: - System Section

private struct SystemSection: View {
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var hooksInstalled: Bool = HookInstaller.isInstalled()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(L10n.settingsSystem)

            settingsGroup {
                MenuToggleRow(
                    icon: "power",
                    label: L10n.launchAtLogin,
                    isOn: launchAtLogin
                ) {
                    do {
                        if launchAtLogin {
                            try SMAppService.mainApp.unregister()
                            launchAtLogin = false
                        } else {
                            try SMAppService.mainApp.register()
                            launchAtLogin = true
                        }
                    } catch {
                        print("Failed to toggle launch at login: \(error)")
                    }
                }

                Divider()

                MenuToggleRow(
                    icon: "arrow.triangle.2.circlepath",
                    label: L10n.hooks,
                    isOn: hooksInstalled
                ) {
                    if hooksInstalled {
                        HookInstaller.uninstall()
                        hooksInstalled = false
                    } else {
                        HookInstaller.installIfNeeded()
                        hooksInstalled = true
                    }
                }

                Divider()

                AccessibilityRow(isEnabled: AXIsProcessTrusted())
            }

            #if !APP_STORE
            settingsGroup {
                UpdateRow(updateManager: UpdateManager.shared)
            }
            #endif
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
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(L10n.license)

            // Status
            settingsGroup {
                HStack {
                    Text(L10n.license)
                        .font(.system(size: 13))
                    Spacer()
                    statusBadge
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if licenseManager.status == .activated {
                    Divider()
                    HStack {
                        Text(licenseManager.maskedKey)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(L10n.licenseDeviceCount(licenseManager.activationCount, licenseManager.activationLimit))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }

            // Activate (if not activated)
            if licenseManager.status != .activated {
                settingsGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.licenseActivate)
                            .font(.system(size: 12, weight: .medium))

                        HStack(spacing: 8) {
                            TextField(L10n.licenseKeyPlaceholder, text: $licenseKeyInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .disabled(isActivating)
                                .onSubmit { doActivate() }

                            Button {
                                doActivate()
                            } label: {
                                if isActivating {
                                    ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                                } else {
                                    Text(L10n.licenseActivate)
                                }
                            }
                            .disabled(licenseKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isActivating)
                        }

                        if let err = licenseManager.errorMessage {
                            Text(err)
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                        }

                        Button {
                            if let url = URL(string: PolarAPIClient.checkoutURL) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "cart")
                                    .font(.system(size: 11))
                                Text(L10n.licensePurchase)
                                    .font(.system(size: 12))
                            }
                        }
                        .buttonStyle(.link)
                    }
                    .padding(12)
                }
            }

            // Manage (if activated)
            if licenseManager.status == .activated {
                settingsGroup {
                    HStack {
                        if showConfirmDeactivate {
                            Text(L10n.licenseDeactivateDevice)
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                            Spacer()
                            Button(L10n.licenseDeactivateDevice) {
                                Task {
                                    await licenseManager.deactivateThisDevice()
                                    showConfirmDeactivate = false
                                }
                            }
                            .foregroundColor(.red)
                        } else {
                            Text(L10n.licenseManage)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(L10n.licenseDeactivateDevice) {
                                showConfirmDeactivate = true
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch licenseManager.status {
        case .activated:
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text(L10n.licenseActivated).font(.system(size: 11)).foregroundColor(.green)
            }
        case .trial:
            HStack(spacing: 4) {
                Circle().fill(.orange).frame(width: 6, height: 6)
                Text(L10n.trialTimeRemaining(hours: licenseManager.trialHoursRemaining))
                    .font(.system(size: 11)).foregroundColor(.orange)
            }
        case .locked:
            HStack(spacing: 4) {
                Circle().fill(.red).frame(width: 6, height: 6)
                Text(L10n.trialExpiredTitle).font(.system(size: 11)).foregroundColor(.red)
            }
        case .validating:
            ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
        }
    }

    private func doActivate() {
        let trimmed = licenseKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isActivating else { return }
        isActivating = true
        Task {
            await licenseManager.activate(key: trimmed)
            isActivating = false
            if licenseManager.status == .activated {
                licenseKeyInput = ""
            }
        }
    }
}
#endif

// MARK: - Helpers

private func sectionHeader(_ title: String) -> some View {
    Text(title)
        .font(.system(size: 18, weight: .semibold))
}

private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(spacing: 0) {
        content()
    }
    .background(
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor))
    )
}
