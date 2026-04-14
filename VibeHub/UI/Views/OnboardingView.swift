import SwiftUI

/// First-launch onboarding: mode selection + hook installation in one flow.
struct OnboardingView: View {
    @ObservedObject var viewModel: NotchViewModel
    @State private var selectedMode: DisplayMode = .notch
    @State private var showDetail = false
    @State private var step: OnboardingStep = .modeSelection
    @State private var isInstalling = false
    @State private var installDone = false

    private enum OnboardingStep {
        case modeSelection
        case hookInstall
    }

    var body: some View {
        VStack(spacing: 16) {
            // App icon + title (shared)
            VStack(spacing: 8) {
                if let appIcon = NSImage(named: "AppIcon") {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                }
                Text(L10n.welcomeTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }

            switch step {
            case .modeSelection:
                modeSelectionContent
            case .hookInstall:
                hookInstallContent
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.2), value: step)
    }

    // MARK: - Step 1: Mode Selection

    private var modeSelectionContent: some View {
        VStack(spacing: 16) {
            Text(L10n.onboardingTitle)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))

            // Mode cards
            HStack(spacing: 12) {
                modeCard(
                    mode: .notch,
                    title: L10n.onboardingNotchTitle,
                    description: L10n.onboardingNotchDesc
                ) { NotchPreview() }

                modeCard(
                    mode: .menuBar,
                    title: L10n.onboardingMenuBarTitle,
                    description: L10n.onboardingMenuBarDesc
                ) { MenuBarPreview(showDetail: showDetail) }
            }

            // Detail toggle (only for menu bar)
            if selectedMode == .menuBar {
                HStack(spacing: 8) {
                    Image(systemName: showDetail ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14))
                        .foregroundColor(showDetail ? .white : .white.opacity(0.4))
                    Text(L10n.onboardingShowDetail)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                }
                .onTapGesture { showDetail.toggle() }
            }

            // Next button
            Button {
                AppSettings.displayMode = selectedMode
                AppSettings.menuBarShowDetail = showDetail
                step = .hookInstall
            } label: {
                Text(L10n.next)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Step 2: Hook Installation

    private var hookInstallContent: some View {
        VStack(spacing: 16) {
            Text(L10n.welcomeSubtitle)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            Text(L10n.welcomeInstallStep)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 4)

            // Install button
            Button {
                guard !isInstalling else { return }
                Task { @MainActor in
                    isInstalling = true
                    let success = await performInstall()
                    isInstalling = false
                    if success {
                        installDone = true
                        finishOnboarding()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if isInstalling {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12))
                    }
                    Text(isInstalling ? L10n.welcomeInstallingButton : L10n.welcomeInstallButton)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
            }
            .buttonStyle(.plain)
            .disabled(isInstalling)

            // Skip button
            Button {
                finishOnboarding()
            } label: {
                Text(L10n.welcomeSkipButton)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Finish

    private func finishOnboarding() {
        AppSettings.hasCompletedOnboarding = true
        NotificationCenter.default.post(name: .displayModeChanged, object: nil)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            viewModel.contentType = .instances
        }
    }

    // MARK: - Install

    @MainActor
    private func performInstall() async -> Bool {
        #if APP_STORE
        return await performInstallAppStore()
        #else
        // Dev builds auto-install hooks via CLIInstaller (handles every CLI).
        HookInstaller.installIfNeeded()
        return true
        #endif
    }

    #if APP_STORE
    @MainActor
    private func performInstallAppStore() async -> Bool {
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
            return false
        }

        _ = HookInstaller.rememberClaudeDir(homeDir)

        let ok = homeDir.startAccessingSecurityScopedResource()
        defer { if ok { homeDir.stopAccessingSecurityScopedResource() } }
        guard ok else { return false }

        let claudeDir = homeDir.appendingPathComponent(".claude", isDirectory: true)
        let ok1 = HookInstaller.installAppStore(claudeDir: claudeDir)

        let opencodeDir = homeDir
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
        if FileManager.default.fileExists(atPath: opencodeDir.appendingPathComponent("opencode.json").path) {
            _ = HookInstaller.installOpenCodeAppStore(opencodeDir: opencodeDir)
        }

        return ok1
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

        let resp = withNotchWindowDeemphasized { panel.runModal() }
        guard resp == .OK, let url = panel.url else { return nil }

        let chosen = url.standardizedFileURL.resolvingSymlinksInPath().path
        let required = URL(fileURLWithPath: requiredPath).standardizedFileURL.resolvingSymlinksInPath().path
        guard chosen == required else { return nil }
        return url
    }

    @MainActor
    private func withNotchWindowDeemphasized<T>(_ block: () -> T) -> T {
        let notchWindow = NSApp.windows.first(where: { $0 is NotchPanel })
        let prevLevel = notchWindow?.level
        notchWindow?.level = .normal
        NSApp.activate(ignoringOtherApps: true)
        defer { if let prevLevel { notchWindow?.level = prevLevel } }
        return block()
    }
    #endif

    // MARK: - Mode Card

    private func modeCard<Preview: View>(
        mode: DisplayMode,
        title: String,
        description: String,
        @ViewBuilder preview: () -> Preview
    ) -> some View {
        let selected = selectedMode == mode
        return VStack(spacing: 8) {
            preview()
                .frame(height: 80)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
            Text(description)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(selected ? Color.white.opacity(0.1) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? Color.white.opacity(0.4) : Color.white.opacity(0.1), lineWidth: selected ? 1.5 : 0.5)
        )
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { selectedMode = mode } }
    }
}

// MARK: - Notch Mode Preview

private struct NotchPreview: View {
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 20)

                HStack(spacing: 0) {
                    Spacer()
                    HStack(spacing: 4) {
                        ClaudeCrabIcon(size: 8, animateLegs: true)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.3))
                            .frame(width: 30, height: 4)
                        Circle()
                            .fill(Color.green.opacity(0.8))
                            .frame(width: 5, height: 5)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black))
                    Spacer()
                }
                .padding(.top, 2)
            }

            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.06)).frame(height: 12)
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.04)).frame(height: 12)
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.03))
                    .frame(width: 80, height: 12).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
        }
    }
}

// MARK: - Menu Bar Mode Preview

private struct MenuBarPreview: View {
    let showDetail: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Spacer()
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 10, height: 5)
                }
                HStack(spacing: 3) {
                    if showDetail {
                        Text("proj · task")
                            .font(.system(size: 6, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    ClaudeCrabIcon(size: 8, color: .green, animateLegs: true)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.1)))
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Color.white.opacity(0.08))

            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.06)).frame(height: 12)
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.04)).frame(height: 12)
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.03))
                    .frame(width: 80, height: 12).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
        }
    }
}
