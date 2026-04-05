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
    @State private var showActivateInput = false
    @State private var licenseKeyInput = ""
    @State private var isActivating = false

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

                switch licenseManager.status {
                case .activated:
                    HStack(spacing: 6) {
                        Circle()
                            .fill(TerminalColors.green)
                            .frame(width: 6, height: 6)
                        Text(L10n.licenseActivated)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                    }
                case .trial:
                    HStack(spacing: 6) {
                        Circle()
                            .fill(TerminalColors.amber)
                            .frame(width: 6, height: 6)
                        Text(L10n.trialTimeRemaining(hours: licenseManager.trialHoursRemaining))
                            .font(.system(size: 11))
                            .foregroundColor(TerminalColors.amber.opacity(0.8))
                    }
                default:
                    EmptyView()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
            )
            .onHover { isHovered = $0 }

            if licenseManager.status == .trial {
                // Trial: purchase + activate buttons
                HStack(spacing: 8) {
                    Spacer().frame(width: 16)

                    Button {
                        if let url = URL(string: PolarAPIClient.checkoutURL) {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Text(L10n.licensePurchase)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)

                    Text("·")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.25))

                    Button {
                        showActivateInput.toggle()
                    } label: {
                        Text(L10n.licenseActivate)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(TerminalColors.amber.opacity(0.8))
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                if showActivateInput {
                    VStack(spacing: 6) {
                        TextField(L10n.licenseKeyPlaceholder, text: $licenseKeyInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.white.opacity(0.08))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15), lineWidth: 1))
                            )
                            .padding(.horizontal, 12)
                            .disabled(isActivating)
                            .onSubmit { doActivate() }

                        if let err = licenseManager.errorMessage {
                            Text(err)
                                .font(.system(size: 10))
                                .foregroundColor(Color(red: 1.0, green: 0.4, blue: 0.4))
                                .padding(.horizontal, 12)
                        }

                        HStack {
                            Spacer().frame(width: 28)
                            Button {
                                doActivate()
                            } label: {
                                Text(isActivating ? L10n.licenseActivating : L10n.licenseActivate)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(licenseKeyInput.isEmpty ? 0.4 : 1.0)))
                            }
                            .buttonStyle(.plain)
                            .disabled(licenseKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isActivating)
                            Spacer()
                        }
                        .padding(.bottom, 4)
                    }
                }
            } else if licenseManager.status == .activated {
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
                HStack {
                    Spacer().frame(width: 16)

                    if showConfirmDeactivate {
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
                    } else {
                        Button {
                            showConfirmDeactivate = true
                        } label: {
                            Text(L10n.licenseManage)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func doActivate() {
        let trimmed = licenseKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isActivating else { return }
        isActivating = true
        Task {
            await licenseManager.activate(key: trimmed)
            isActivating = false
            if licenseManager.status == .activated {
                showActivateInput = false
                licenseKeyInput = ""
            }
        }
    }

    private var statusColor: Color {
        switch licenseManager.status {
        case .activated: return TerminalColors.green
        case .trial: return TerminalColors.amber
        case .locked: return Color(red: 1.0, green: 0.4, blue: 0.4)
        case .validating: return .white.opacity(0.5)
        }
    }
}

#endif
