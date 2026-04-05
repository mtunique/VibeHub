//
//  LicenseManager.swift
//  VibeHub
//
//  Orchestrates license validation, activation, and state
//

import Combine
import Foundation

#if !APP_STORE

@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    @Published var status: LicenseStatus = .locked
    @Published var errorMessage: String?
    @Published var activationCount: Int = 0
    @Published var activationLimit: Int = 3
    @Published var trialDaysRemaining: Int = TrialData.trialDays

    private let cacheKey = "license_cache"
    private let trialKey = "trial_data"
    private let offlineGraceDays: TimeInterval = 7 * 24 * 60 * 60  // 7 days

    private init() {}

    // MARK: - Startup Validation

    /// Called at app launch. Returns true if the app should proceed, false if locked.
    func validateOnStartup() async -> Bool {
        // If no license, check/start trial
        guard let cache = KeychainStore.load(LicenseCache.self, forKey: cacheKey) else {
            return checkTrial()
        }

        status = .validating

        do {
            let response = try await PolarAPIClient.validate(
                key: cache.licenseKey,
                activationId: cache.activationId
            )

            if response.status == "granted" {
                updateCache(from: cache, validationDate: Date())
                updateActivationInfo(from: response)
                status = .activated
                return true
            } else {
                // Key was revoked or disabled
                KeychainStore.delete(forKey: cacheKey)
                status = .locked
                return false
            }
        } catch {
            // Network error — check offline cache
            let elapsed = Date().timeIntervalSince(cache.lastValidationDate)
            if elapsed < offlineGraceDays {
                status = .activated
                return true
            } else {
                status = .locked
                return false
            }
        }
    }

    // MARK: - Activate

    func activate(key: String) async {
        status = .validating
        errorMessage = nil

        let hardwareId = HardwareFingerprint.deviceId
        let label = HardwareFingerprint.deviceLabel

        do {
            // Step 1: Activate device
            let activation = try await PolarAPIClient.activate(
                key: key,
                hardwareId: hardwareId,
                label: label
            )

            // Step 2: Validate to confirm and get full status
            let validation = try await PolarAPIClient.validate(
                key: key,
                activationId: activation.id
            )

            guard validation.status == "granted" else {
                status = .locked
                errorMessage = L10n.licenseKeyRevoked
                return
            }

            // Step 3: Save to Keychain
            let cache = LicenseCache(
                licenseKey: key,
                activationId: activation.id,
                lastValidationDate: Date(),
                hardwareId: hardwareId
            )
            _ = KeychainStore.save(cache, forKey: cacheKey)

            updateActivationInfo(from: validation)
            status = .activated
        } catch let error as PolarAPIError {
            status = trialStatus()
            switch error {
            case .invalidKey:
                errorMessage = L10n.licenseKeyInvalid
            case .deviceLimitReached:
                errorMessage = L10n.licenseDeviceLimit
            case .keyRevoked:
                errorMessage = L10n.licenseKeyRevoked
            case .networkError:
                errorMessage = L10n.licenseNetworkError
            case .unexpectedResponse:
                errorMessage = L10n.licenseNetworkError
            }
        } catch {
            status = trialStatus()
            errorMessage = L10n.licenseNetworkError
        }
    }

    // MARK: - Deactivate

    func deactivateThisDevice() async {
        guard let cache = KeychainStore.load(LicenseCache.self, forKey: cacheKey) else { return }

        do {
            try await PolarAPIClient.deactivate(
                key: cache.licenseKey,
                activationId: cache.activationId
            )
        } catch {
            // Best-effort: still remove local data even if API fails
        }

        KeychainStore.delete(forKey: cacheKey)
        status = .locked
        activationCount = 0
    }

    // MARK: - Accessors

    var maskedKey: String {
        guard let cache = KeychainStore.load(LicenseCache.self, forKey: cacheKey) else { return "" }
        let key = cache.licenseKey
        if key.count > 8 {
            let suffix = String(key.suffix(4))
            return String(repeating: "•", count: min(key.count - 4, 16)) + suffix
        }
        return key
    }

    // MARK: - Trial

    /// Returns true if trial is active, false if expired
    private func checkTrial() -> Bool {
        let trial = getOrCreateTrial()
        trialDaysRemaining = trial.daysRemaining
        if trial.isExpired {
            status = .locked
            return false
        } else {
            status = .trial
            return true
        }
    }

    private func getOrCreateTrial() -> TrialData {
        if let existing = KeychainStore.load(TrialData.self, forKey: trialKey) {
            return existing
        }
        let newTrial = TrialData(startDate: Date())
        _ = KeychainStore.save(newTrial, forKey: trialKey)
        return newTrial
    }

    /// Status to fall back to when activation fails (trial if active, locked if expired)
    private func trialStatus() -> LicenseStatus {
        guard let trial = KeychainStore.load(TrialData.self, forKey: trialKey) else { return .locked }
        return trial.isExpired ? .locked : .trial
    }

    // MARK: - Private

    private func updateCache(from existing: LicenseCache, validationDate: Date) {
        let updated = LicenseCache(
            licenseKey: existing.licenseKey,
            activationId: existing.activationId,
            lastValidationDate: validationDate,
            hardwareId: existing.hardwareId
        )
        _ = KeychainStore.save(updated, forKey: cacheKey)
    }

    private func updateActivationInfo(from response: PolarValidateResponse) {
        activationCount = response.activations?.count ?? 0
        activationLimit = response.limit_activations ?? 3
    }
}

#endif
