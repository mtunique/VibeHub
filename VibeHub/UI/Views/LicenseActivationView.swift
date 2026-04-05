//
//  LicenseActivationView.swift
//  VibeHub
//
//  Full-screen lock view shown when no valid license is present
//

import SwiftUI

#if !APP_STORE

struct LicenseActivationView: View {
    @ObservedObject var licenseManager: LicenseManager
    @State private var licenseKey: String = ""
    @State private var isActivating = false

    var body: some View {
        VStack(spacing: 16) {
            // App icon
            if let appIcon = NSImage(named: "AppIcon") {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
            }

            // Title
            Text(L10n.licenseLockedTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)

            // Subtitle
            Text(L10n.licenseLockedSubtitle)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)

            Spacer().frame(height: 4)

            // License key input
            TextField(L10n.licenseKeyPlaceholder, text: $licenseKey)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.white)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                )
                .disabled(isActivating)
                .onSubmit {
                    activateIfReady()
                }

            // Error message
            if let error = licenseManager.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 1.0, green: 0.4, blue: 0.4))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Activate button
            Button {
                activateIfReady()
            } label: {
                HStack(spacing: 6) {
                    if isActivating {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                    Text(isActivating ? L10n.licenseActivating : L10n.licenseActivate)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(licenseKey.isEmpty || isActivating ? Color.white.opacity(0.5) : Color.white)
                )
            }
            .buttonStyle(.plain)
            .disabled(licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isActivating)

            // Purchase button
            Button {
                if let url = URL(string: PolarAPIClient.checkoutURL) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text(L10n.licensePurchase)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            }
            .buttonStyle(.plain)

            // Quit button
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text(L10n.quit)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.3))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
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
