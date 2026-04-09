//
//  NotchMenuView.swift
//  VibeHub
//
//  Minimal menu matching Dynamic Island aesthetic
//

import ApplicationServices
import AppKit
import Combine
import SwiftUI
import ServiceManagement

#if !APP_STORE
import Sparkle
#endif

// MARK: - NotchMenuView

struct NotchMenuView: View {
    @ObservedObject var viewModel: NotchViewModel
    var showBackButton: Bool = true

    var body: some View {
        VStack(spacing: 4) {
            if showBackButton {
                MenuRow(icon: "chevron.left", label: L10n.back) {
                    viewModel.toggleMenu()
                }
                Divider().background(Color.white.opacity(0.08)).padding(.vertical, 4)
            }

            MenuRow(icon: "gearshape", label: L10n.settingsTitle) {
                SettingsWindowController.shared.show()
            }

            MenuRow(icon: "xmark.circle", label: L10n.quit, isDestructive: true) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

#if APP_STORE
    @MainActor
    private func installOrUninstallHooksAppStore() async {
        if hooksInstalled {
            let ok = HookInstaller.uninstallAppStore()
            refreshStates()
            showMessage(title: "Hooks", message: ok ? "Uninstalled." : "Uninstall completed with errors.")
            return
        }

        // In sandbox, FileManager.homeDirectoryForCurrentUser returns the
        // container path. Use getpwuid to get the real home directory.
        let home: URL = {
            if let pw = getpwuid(getuid()) {
                return URL(fileURLWithPath: String(cString: pw.pointee.pw_dir))
            }
            return FileManager.default.homeDirectoryForCurrentUser
        }()

        guard let homeDir = pickDirectory(
            title: "Grant Access",
            message: "Select your Home folder (\(home.path)) to grant access for installing hooks.",
            suggested: home,
            requiredPath: home.standardizedFileURL.path
        ) else {
            return
        }

        // Persist access to Home; allows access to ~/.claude and ~/.config/opencode as descendants.
        _ = HookInstaller.rememberClaudeDir(homeDir)

        let claudeOk = homeDir.startAccessingSecurityScopedResource()
        defer { if claudeOk { homeDir.stopAccessingSecurityScopedResource() } }
        guard claudeOk else {
            showMessage(title: "Hooks", message: "Permission denied for Home folder.")
            return
        }

        let claudeDir = homeDir.appendingPathComponent(".claude", isDirectory: true)
        let ok1 = HookInstaller.installAppStore(claudeDir: claudeDir)

        var ok2 = true
        let wantsOpenCode = withNotchWindowDeemphasized {
            NSAlert.runChoice(
                title: "OpenCode",
                message: "Also install the OpenCode plugin (uses ~/.config/opencode if present)?",
                primary: "Install",
                secondary: "Skip"
            )
        }

        if wantsOpenCode {
            let opencodeDir = homeDir
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("opencode", isDirectory: true)
            ok2 = HookInstaller.installOpenCodeAppStore(opencodeDir: opencodeDir)
        }

        refreshStates()
        if ok1 && ok2 {
            showMessage(title: "Hooks", message: "Installed.")
        } else if ok1 {
            showMessage(title: "Hooks", message: "Installed Claude hooks, but OpenCode plugin failed.")
        } else {
            showMessage(title: "Hooks", message: "Install failed.")
        }
    }

    @MainActor
    private func pickDirectory(title: String, message: String, suggested: URL, requiredPath: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = "Allow"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = suggested.deletingLastPathComponent()
        panel.nameFieldStringValue = suggested.lastPathComponent

        // Ensure the modal panel is in front of the notch overlay.
        let resp = withNotchWindowDeemphasized { panel.runModal() }
        guard resp == .OK, let url = panel.url else { return nil }

        let chosen = url.standardizedFileURL.resolvingSymlinksInPath().path
        let required = URL(fileURLWithPath: requiredPath).standardizedFileURL.resolvingSymlinksInPath().path
        guard chosen == required else {
            showMessage(title: "Hooks", message: "Please select \(required).")
            return nil
        }
        return url
    }

    @MainActor
    private func showMessage(title: String, message: String) {
        _ = withNotchWindowDeemphasized {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = message
            a.addButton(withTitle: "OK")
            a.runModal()
        }
    }

    @MainActor
    private func withNotchWindowDeemphasized<T>(_ block: () -> T) -> T {
        let notchWindow = NSApp.windows.first(where: { $0 is NotchPanel })
        let prevLevel = notchWindow?.level
        // Put the overlay behind modal dialogs.
        notchWindow?.level = .normal
        NSApp.activate(ignoringOtherApps: true)
        defer {
            if let prevLevel { notchWindow?.level = prevLevel }
        }
        return block()
    }
#endif
}

#if APP_STORE
private extension NSAlert {
    @MainActor
    static func runChoice(title: String, message: String, primary: String, secondary: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: primary)
        a.addButton(withTitle: secondary)
        return a.runModal() == .alertFirstButtonReturn
    }
}
#endif

// MARK: - Update Row

#if !APP_STORE

struct UpdateRow: View {
    @ObservedObject var updateManager: UpdateManager
    @State private var isHovered = false
    @State private var isSpinning = false

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

    var body: some View {
        Button {
            handleTap()
        } label: {
            HStack(spacing: 10) {
                // Icon
                ZStack {
                    if case .installing = updateManager.state {
                        Image(systemName: "gear")
                            .font(.system(size: 12))
                            .foregroundColor(TerminalColors.blue)
                            .rotationEffect(.degrees(isSpinning ? 360 : 0))
                            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isSpinning)
                            .onAppear { isSpinning = true }
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 12))
                            .foregroundColor(iconColor)
                    }
                }
                .frame(width: 16)

                // Label
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(labelColor)

                Spacer()

                // Right side: progress or status
                rightContent
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered && isInteractive ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.2), value: updateManager.state)
    }

    // MARK: - Right Content

    @ViewBuilder
    private var rightContent: some View {
        switch updateManager.state {
        case .idle:
            Text(appVersion)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))

        case .upToDate:
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(TerminalColors.green)
                Text(L10n.upToDate)
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.green)
            }

        case .checking, .installing:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)

        case .found(let version, _):
            HStack(spacing: 6) {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)
                Text("v\(version)")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.green)
            }

        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 60)
                    .tint(TerminalColors.blue)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TerminalColors.blue)
                    .frame(width: 32, alignment: .trailing)
            }

        case .extracting(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 60)
                    .tint(TerminalColors.amber)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TerminalColors.amber)
                    .frame(width: 32, alignment: .trailing)
            }

        case .readyToInstall(let version):
            HStack(spacing: 6) {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)
                Text("v\(version)")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.green)
            }

        case .error:
            Text(L10n.retry)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
        }
    }

    // MARK: - Computed Properties

    private var icon: String {
        switch updateManager.state {
        case .idle:
            return "arrow.down.circle"
        case .checking:
            return "arrow.down.circle"
        case .upToDate:
            return "checkmark.circle.fill"
        case .found:
            return "arrow.down.circle.fill"
        case .downloading:
            return "arrow.down.circle"
        case .extracting:
            return "doc.zipper"
        case .readyToInstall:
            return "checkmark.circle.fill"
        case .installing:
            return "gear"
        case .error:
            return "exclamationmark.circle"
        }
    }

    private var iconColor: Color {
        switch updateManager.state {
        case .idle:
            return .white.opacity(isHovered ? 1.0 : 0.7)
        case .checking:
            return .white.opacity(0.7)
        case .upToDate:
            return TerminalColors.green
        case .found, .readyToInstall:
            return TerminalColors.green
        case .downloading:
            return TerminalColors.blue
        case .extracting:
            return TerminalColors.amber
        case .installing:
            return TerminalColors.blue
        case .error:
            return Color(red: 1.0, green: 0.4, blue: 0.4)
        }
    }

    private var label: String {
        switch updateManager.state {
        case .idle:
            return L10n.checkForUpdates
        case .checking:
            return L10n.checking
        case .upToDate:
            return L10n.upToDate
        case .found:
            return L10n.downloadUpdate
        case .downloading:
            return L10n.downloading
        case .extracting:
            return L10n.extracting
        case .readyToInstall:
            return L10n.installAndRelaunch
        case .installing:
            return L10n.installing
        case .error:
            return L10n.updateFailed
        }
    }

    private var labelColor: Color {
        switch updateManager.state {
        case .idle, .upToDate:
            return .white.opacity(isHovered ? 1.0 : 0.7)
        case .checking, .downloading, .extracting, .installing:
            return .white.opacity(0.9)
        case .found, .readyToInstall:
            return TerminalColors.green
        case .error:
            return Color(red: 1.0, green: 0.4, blue: 0.4)
        }
    }

    private var isInteractive: Bool {
        switch updateManager.state {
        case .idle, .upToDate, .found, .readyToInstall, .error:
            return true
        case .checking, .downloading, .extracting, .installing:
            return false
        }
    }

    // MARK: - Actions

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

// MARK: - Accessibility Permission Row

struct AccessibilityRow: View {
    let isEnabled: Bool

    @State private var isHovered = false
    @State private var refreshTrigger = false

    private var currentlyEnabled: Bool {
        // Re-check on each render when refreshTrigger changes
        _ = refreshTrigger
        return isEnabled
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised")
                .font(.system(size: 12))
                .foregroundColor(textColor)
                .frame(width: 16)

            Text(L10n.accessibility)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(textColor)

            Spacer()

            if isEnabled {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)

                Text(L10n.on)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                Button(action: openAccessibilitySettings) {
                    Text(L10n.enable)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.white)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
        )
        .onHover { isHovered = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshTrigger.toggle()
        }
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct MenuRow: View {
    let icon: String
    let label: String
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var textColor: Color {
        if isDestructive {
            return Color(red: 1.0, green: 0.4, blue: 0.4)
        }
        return .white.opacity(isHovered ? 1.0 : 0.7)
    }
}

struct DisplayModePicker: View {
    @Binding var currentMode: DisplayMode

    private let modes: [(DisplayMode, String, String)] = [
        (.auto, "sparkles", L10n.displayModeAuto),
        (.notch, "rectangle.topthird.inset.filled", L10n.displayModeNotch),
        (.menuBar, "menubar.rectangle", L10n.displayModeMenuBar),
    ]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "display")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 20, alignment: .center)
            Text(L10n.displayModeLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
            Spacer()
            HStack(spacing: 2) {
                ForEach(modes, id: \.0) { mode, icon, label in
                    Button {
                        currentMode = mode
                        AppSettings.displayMode = mode
                        NotificationCenter.default.post(name: .displayModeChanged, object: nil)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: icon).font(.system(size: 9))
                            Text(label).font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(currentMode == mode ? .white : .white.opacity(0.4))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(currentMode == mode ? Color.white.opacity(0.15) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct MenuToggleRow: View {
    let icon: String
    let label: String
    let isOn: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()

                Circle()
                    .fill(isOn ? TerminalColors.green : Color.white.opacity(0.3))
                    .frame(width: 6, height: 6)

                Text(isOn ? L10n.on : L10n.off)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }
}

// MARK: - Notification Section Header

struct NotifySectionHeader: View {
    let label: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.35))
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 0)
    }
}

// MARK: - Per-Behavior Notify Mode Picker

struct NotifyModePicker: View {
    let icon: String
    let label: String
    @Binding var mode: NotifyMode
    let onChange: (NotifyMode) -> Void

    private let modes: [(NotifyMode, String)] = [
        (.never, L10n.notifyNever),
        (.backgroundOnly, L10n.notifyBackgroundOnly),
        (.always, L10n.notifyAlways),
    ]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 16)

            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.7))

            Spacer()

            HStack(spacing: 4) {
                ForEach(modes, id: \.0) { m, title in
                    Button {
                        mode = m
                        onChange(m)
                    } label: {
                        Text(title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(mode == m ? colorForMode(m) : .white.opacity(0.35))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(mode == m ? colorForMode(m).opacity(0.15) : Color.white.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func colorForMode(_ m: NotifyMode) -> Color {
        switch m {
        case .never: return Color.white.opacity(0.5)
        case .backgroundOnly: return TerminalColors.amber
        case .always: return TerminalColors.green
        }
    }
}
