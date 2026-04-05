//
//  LicenseSettingsView.swift
//  VibeHub
//
//  License status and management section for settings menu
//

import SwiftUI

#if !APP_STORE

struct LicenseSettingsView: View {
    @ObservedObject var licenseManager: LicenseManager
    @State private var isHovered = false
    @State private var showConfirmDeactivate = false

    var body: some View {
        VStack(spacing: 4) {
            // Status row
            HStack(spacing: 10) {
                Image(systemName: "key")
                    .font(.system(size: 12))
                    .foregroundColor(statusColor)
                    .frame(width: 16)

                Text(L10n.license)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))

                Spacer()

                if licenseManager.status == .activated {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(TerminalColors.green)
                            .frame(width: 6, height: 6)
                        Text(L10n.licenseActivated)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
            )
            .onHover { isHovered = $0 }

            if licenseManager.status == .activated {
                // Key display
                HStack(spacing: 10) {
                    Spacer().frame(width: 16)

                    Text(licenseManager.maskedKey)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))

                    Spacer()

                    Text(L10n.licenseDeviceCount(licenseManager.activationCount, licenseManager.activationLimit))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                // Deactivate button
                if showConfirmDeactivate {
                    HStack {
                        Spacer().frame(width: 16)

                        Button {
                            Task {
                                await licenseManager.deactivateThisDevice()
                                showConfirmDeactivate = false
                            }
                        } label: {
                            Text(L10n.licenseDeactivateDevice)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(red: 1.0, green: 0.4, blue: 0.4))
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                } else {
                    HStack {
                        Spacer().frame(width: 16)

                        Button {
                            showConfirmDeactivate = true
                        } label: {
                            Text(L10n.licenseManage)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var statusColor: Color {
        switch licenseManager.status {
        case .activated: return TerminalColors.green
        case .locked: return Color(red: 1.0, green: 0.4, blue: 0.4)
        case .validating: return .white.opacity(0.5)
        }
    }
}

#endif
