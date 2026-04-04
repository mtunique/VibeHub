import SwiftUI

/// SwiftUI content for the menu bar popover. Reuses the same content views as NotchView.
struct MenuBarContentView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject var sessionMonitor: ClaudeSessionMonitor

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
            Text("VibeHub")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            headerButtons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var headerButtons: some View {
        HStack(spacing: 8) {
            headerButton(icon: "list.bullet", type: .instances)
            headerButton(icon: "gearshape", type: .menu)
        }
    }

    private func headerButton(icon: String, type: NotchContentType) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                viewModel.contentType = type
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(viewModel.contentType == type ? .white : .gray)
                .frame(width: 24, height: 24)
                .background(viewModel.contentType == type ? Color.white.opacity(0.15) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        Group {
            switch viewModel.contentType {
            case .instances:
                ClaudeInstancesView(
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
            case .menu:
                ScrollView {
                    NotchMenuView(viewModel: viewModel)
                }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
