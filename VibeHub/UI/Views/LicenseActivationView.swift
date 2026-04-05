//
//  LicenseActivationView.swift
//  VibeHub
//
//  Compact lock view shown when no valid license is present
//

import SwiftUI

#if !APP_STORE

struct LicenseActivationView: View {
    @ObservedObject var licenseManager: LicenseManager
    @State private var licenseKey: String = ""
    @State private var isActivating = false

    private var isTrialExpired: Bool {
        licenseManager.trialHoursRemaining == 0 && licenseManager.activationCount == 0
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 8)

            // Icon + title
            HStack(spacing: 10) {
                Image(systemName: isTrialExpired ? "clock.badge.exclamationmark" : "key")
                    .font(.system(size: 18))
                    .foregroundColor(isTrialExpired
                        ? Color(red: 1.0, green: 0.4, blue: 0.4)
                        : .white.opacity(0.6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(isTrialExpired ? L10n.trialExpiredTitle : L10n.licenseLockedTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    Text(isTrialExpired ? L10n.trialExpiredSubtitle : L10n.licenseLockedSubtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                }
                Spacer()
            }

            // Input + activate in a row
            HStack(spacing: 8) {
                TextField(L10n.licenseKeyPlaceholder, text: $licenseKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                    )
                    .disabled(isActivating)
                    .onSubmit { activateIfReady() }

                Button {
                    activateIfReady()
                } label: {
                    Group {
                        if isActivating {
                            ProgressView()
                                .scaleEffect(0.45)
                                .frame(width: 14, height: 14)
                        } else {
                            Text(L10n.licenseActivate)
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(licenseKey.isEmpty || isActivating
                                  ? Color.white.opacity(0.35)
                                  : Color.white)
                    )
                }
                .buttonStyle(.plain)
                .disabled(licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isActivating)
            }

            // Error message
            if let error = licenseManager.errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(Color(red: 1.0, green: 0.4, blue: 0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().background(Color.white.opacity(0.08))

            // Bottom actions
            HStack {
                Button {
                    if let url = URL(string: PolarAPIClient.checkoutURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "cart")
                            .font(.system(size: 10))
                        Text(L10n.licensePurchase)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.45))
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text(L10n.quit)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.25))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func activateIfReady() {
        let trimmed = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isActivating else { return }
        isActivating = true
        Task {
            await licenseManager.activate(key: trimmed)
            isActivating = false
        }
    }
}

#endif
