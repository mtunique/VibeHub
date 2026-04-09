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

    private static let mainSections: [SettingsSection] = [.appearance, .notifications, .remote, .system]
    private static let bottomSections: [SettingsSection] = [.about]

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 0) {
                // Top padding for titlebar area
                Spacer().frame(height: 8)

                VStack(spacing: 2) {
                    ForEach(Self.mainSections) { section in
                        sidebarRow(section)
                    }
                }
                .padding(.horizontal, 12)

                Divider()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                VStack(spacing: 2) {
                    ForEach(Self.bottomSections) { section in
                        sidebarRow(section)
                    }
                }
                .padding(.horizontal, 12)

                Spacer()

                // Quit button
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
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .frame(width: 200)
            .background(.primary.opacity(0.03))

            // Divider
            Rectangle()
                .fill(.primary.opacity(0.08))
                .frame(width: 1)

            // Detail
            if let section = selectedSection {
                sectionDetail(section)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func sidebarRow(_ section: SettingsSection) -> some View {
        Button {
            selectedSection = section
        } label: {
            Label {
                Text(section.title)
            } icon: {
                SettingsIcon(systemName: section.icon, color: section.iconColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(selectedSection == section ? 0.1 : 0))
                    .animation(.easeInOut(duration: 0.15), value: selectedSection)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
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
                DisplayModePreview(mode: WindowManager.resolveMode(displayMode), showDetail: menuBarShowDetail)
                    .frame(height: 80)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))

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

// MARK: - Display Mode Preview

private struct DisplayModePreview: View {
    let mode: DisplayMode
    var showDetail: Bool = true
    @ObservedObject private var sessionMonitor = ClaudeSessionMonitor.shared
    @State private var wallpaperImage: NSImage?

    private let barHeight: CGFloat = 23

    private var sampleProject: String {
        sessionMonitor.instances.first?.projectName ?? "proj"
    }

    private var sampleTitle: String {
        sessionMonitor.instances.first?.compactDisplayTitle ?? "fixing bug..."
    }

    private var sessionCount: Int {
        let count = sessionMonitor.instances.count
        return count > 0 ? count : 2
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Desktop wallpaper background
            Group {
                if let image = wallpaperImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(
                        colors: [Color.blue.opacity(0.3), Color.purple.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            // Fixed menu bar — always at top, never moves
            HStack(spacing: 0) {
                Spacer()

                HStack(spacing: 4) {
                    if showDetail {
                        Text("\(sampleProject) · \(sampleTitle)")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(.primary.opacity(mode == .menuBar ? 0.6 : 0.25))
                            .lineLimit(1)
                    }
                    ClaudeCrabIcon(
                        size: 11,
                        color: mode == .menuBar ? .green : Color.secondary.opacity(0.4),
                        animateLegs: mode == .menuBar
                    )
                }
                .padding(.trailing, 10)
            }
            .frame(maxWidth: .infinity)
            .frame(height: barHeight)
            .background(.ultraThinMaterial)

            // Notch overlay
            NotchShape(topCornerRadius: 4, bottomCornerRadius: 8)
                .fill(.black)
                .frame(width: 200, height: barHeight)
                .overlay(
                    HStack(spacing: 5) {
                        ClaudeCrabIcon(size: 11, animateLegs: true)

                        Text(sampleProject)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.white.opacity(0.45))
                        Text("·")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.white.opacity(0.35))
                        Text(sampleTitle)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)

                        Spacer(minLength: 2)

                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.5)
                            .frame(width: 10, height: 10)

                        Text("\(sessionCount)")
                            .font(.system(size: 7, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 12, height: 12)
                            .background(Circle().fill(.white.opacity(0.15)))
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
                )
                .opacity(mode == .notch ? 1 : 0)
                .scaleEffect(mode == .notch ? 1 : 0.8, anchor: .top)
        }
        .frame(maxWidth: .infinity, minHeight: barHeight, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .animation(.easeInOut(duration: 0.3), value: mode)
        .animation(.easeInOut(duration: 0.3), value: showDetail)
        .onAppear { loadWallpaper() }
    }

    private func loadWallpaper() {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = NSImage(contentsOf: url) else { return }
        wallpaperImage = image
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
            .frame(minWidth: 120)
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
