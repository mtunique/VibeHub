import SwiftUI

/// SwiftUI content for the menu bar popover. Reuses the same content views as NotchView.
struct MenuBarContentView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject var sessionMonitor: ClaudeSessionMonitor
    #if !APP_STORE
    @ObservedObject private var licenseManager = LicenseManager.shared
    #endif

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.1))
            content
        }
        .frame(width: 400, height: 520)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            ClaudeCrabIcon(size: 14)
            Text("Vibe Hub")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            headerButtons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var headerButtons: some View {
        Button {
            SettingsWindowController.shared.show()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12))
                .foregroundColor(.gray)
                .frame(width: 24, height: 24)
                .background(Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        Group {
            #if !APP_STORE
            if licenseManager.status == .locked && viewModel.contentType != .menu {
                LicenseActivationView(licenseManager: licenseManager)
            } else {
                normalContent
            }
            #else
            normalContent
            #endif
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var normalContent: some View {
        switch viewModel.contentType {
        case .instances:
            ClaudeInstancesView(
                sessionMonitor: sessionMonitor,
                viewModel: viewModel
            )
        case .menu:
            NotchMenuView(viewModel: viewModel)
        case .remote:
            RemoteHostsView(viewModel: viewModel)
        case .chat(let session):
            ChatView(
                sessionId: session.sessionId,
                initialSession: session,
                sessionMonitor: sessionMonitor,
                viewModel: viewModel
            )
        case .onboarding:
            OnboardingView(viewModel: viewModel)
        #if APP_STORE
        case .welcome:
            OnboardingView(viewModel: viewModel)
        #endif
        }
    }
}
