import AppKit
import SwiftUI

/// Standalone onboarding window, shown before any display mode is active.
class OnboardingWindowController {
    private var window: NSWindow?
    private var onComplete: (() -> Void)?

    func show(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete

        let view = OnboardingStandaloneView {
            self.close()
        }

        let hostingController = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: hostingController)
        w.title = "Vibe Hub"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 480, height: 520))
        w.center()
        w.isMovableByWindowBackground = true
        w.backgroundColor = .black
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.level = .floating

        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        window?.close()
        window = nil
        onComplete?()
        onComplete = nil
    }
}

/// SwiftUI content for the standalone onboarding window.
private struct OnboardingStandaloneView: View {
    let onFinish: () -> Void

    @State private var selectedMode: DisplayMode = .auto
    @State private var showDetail = false
    @State private var step: Int = 0  // 0 = mode, 1 = hooks
    @State private var isInstalling = false

    var body: some View {
        VStack(spacing: 20) {
            // App icon + title
            VStack(spacing: 10) {
                if let appIcon = NSImage(named: "AppIcon") {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 13))
                }
                Text(L10n.welcomeTitle)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
            }
            .padding(.top, 8)

            if step == 0 {
                modeSelectionStep
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            } else {
                hookInstallStep
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(width: 480, height: 520)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
    }

    // MARK: - Step 0: Mode Selection

    private var modeSelectionStep: some View {
        VStack(spacing: 16) {
            Text(L10n.onboardingTitle)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.5))

            HStack(spacing: 12) {
                modeCard(
                    mode: .auto,
                    title: L10n.onboardingAutoTitle,
                    description: L10n.onboardingAutoDesc
                ) { AutoModePreview() }

                modeCard(
                    mode: .notch,
                    title: L10n.onboardingNotchTitle,
                    description: L10n.onboardingNotchDesc
                ) { NotchModePreview() }

                modeCard(
                    mode: .menuBar,
                    title: L10n.onboardingMenuBarTitle,
                    description: L10n.onboardingMenuBarDesc
                ) { MenuBarModePreview(showDetail: showDetail) }
            }

            if selectedMode == .menuBar || selectedMode == .auto {
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

            Text(L10n.onboardingSubtitle)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.35))

            primaryButton(title: L10n.next) {
                AppSettings.displayMode = selectedMode
                AppSettings.menuBarShowDetail = showDetail
                withAnimation(.easeInOut(duration: 0.25)) { step = 1 }
            }
        }
    }

    // MARK: - Step 1: Hook Install

    private var hookInstallStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 32))
                .foregroundColor(.white.opacity(0.6))

            Text(L10n.welcomeSubtitle)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            Text(L10n.welcomeInstallStep)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)

            primaryButton(
                title: isInstalling ? L10n.welcomeInstallingButton : L10n.welcomeInstallButton,
                icon: isInstalling ? nil : "arrow.down.circle.fill",
                isLoading: isInstalling
            ) {
                guard !isInstalling else { return }
                Task { @MainActor in
                    isInstalling = true
                    await performInstall()
                    isInstalling = false
                    finish()
                }
            }
            .disabled(isInstalling)

            Button { finish() } label: {
                Text(L10n.welcomeSkipButton)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Shared

    private func primaryButton(title: String, icon: String? = nil, isLoading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 12))
                }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
        }
        .buttonStyle(.plain)
    }

    private func modeCard<Preview: View>(
        mode: DisplayMode,
        title: String,
        description: String,
        @ViewBuilder preview: () -> Preview
    ) -> some View {
        let selected = selectedMode == mode
        return VStack(spacing: 8) {
            preview()
                .frame(height: 90)
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

    private func finish() {
        AppSettings.hasCompletedOnboarding = true
        onFinish()
    }

    // MARK: - Install

    @MainActor
    private func performInstall() async {
        #if APP_STORE
        await performInstallAppStore()
        #else
        // CLIInstaller handles every enabled CLI (Claude, OpenCode, Codex, forks).
        HookInstaller.installIfNeeded()
        #endif
    }

    #if APP_STORE
    @MainActor
    private func performInstallAppStore() async {
        let home: URL = {
            if let pw = getpwuid(getuid()) {
                return URL(fileURLWithPath: String(cString: pw.pointee.pw_dir))
            }
            return FileManager.default.homeDirectoryForCurrentUser
        }()

        let panel = NSOpenPanel()
        panel.title = "Grant Access"
        panel.message = "Select your Home folder (\(home.path)) to grant access for installing hooks."
        panel.prompt = "Allow"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = home.deletingLastPathComponent()
        panel.nameFieldStringValue = home.lastPathComponent

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let chosen = url.standardizedFileURL.resolvingSymlinksInPath().path
        let required = home.standardizedFileURL.resolvingSymlinksInPath().path
        guard chosen == required else { return }

        _ = HookInstaller.rememberClaudeDir(url)

        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard ok else { return }

        let claudeDir = url.appendingPathComponent(".claude", isDirectory: true)
        _ = HookInstaller.installAppStore(claudeDir: claudeDir)

        let opencodeDir = url.appendingPathComponent(".config/opencode", isDirectory: true)
        if FileManager.default.fileExists(atPath: opencodeDir.appendingPathComponent("opencode.json").path) {
            _ = HookInstaller.installOpenCodeAppStore(opencodeDir: opencodeDir)
        }
    }
    #endif
}

// MARK: - Preview Illustrations

private struct AutoModePreview: View {
    var body: some View {
        VStack(spacing: 6) {
            // Notch half
            ZStack(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 16)
                HStack {
                    Spacer()
                    HStack(spacing: 3) {
                        ClaudeCrabIcon(size: 6, animateLegs: true)
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.white.opacity(0.3)).frame(width: 18, height: 3)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black))
                    Spacer()
                }
                .padding(.top, 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))

            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(0.3))

            // Menu bar half
            HStack(spacing: 3) {
                Spacer()
                RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.2)).frame(width: 8, height: 4)
                ClaudeCrabIcon(size: 6, color: .green)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.1)))
            }
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.vertical, 4)
    }
}

private struct NotchModePreview: View {
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 22)
                HStack {
                    Spacer()
                    HStack(spacing: 4) {
                        ClaudeCrabIcon(size: 9, animateLegs: true)
                        RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.3)).frame(width: 32, height: 4)
                        Circle().fill(Color.green.opacity(0.8)).frame(width: 5, height: 5)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.black))
                    Spacer()
                }
                .padding(.top, 2)
            }
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.06)).frame(height: 14)
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.04)).frame(height: 14)
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.03))
                    .frame(width: 60, height: 14).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
        }
    }
}

private struct MenuBarModePreview: View {
    let showDetail: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Spacer()
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.white.opacity(0.25)).frame(width: 10, height: 5)
                }
                HStack(spacing: 3) {
                    if showDetail {
                        Text("proj · task")
                            .font(.system(size: 6.5, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    ClaudeCrabIcon(size: 9, color: .green, animateLegs: true)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.1)))
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Color.white.opacity(0.08))

            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.06)).frame(height: 14)
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.04)).frame(height: 14)
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.03))
                    .frame(width: 60, height: 14).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
        }
    }
}
