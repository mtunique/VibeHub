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
    @Published var trialHoursRemaining: Int = TrialData.trialDays * 24

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
            let response = try await LemonSqueezyAPIClient.validate(
                key: cache.licenseKey,
                instanceId: cache.activationId
            )

            if response.valid, let lk = response.license_key, lk.status == "active" {
                updateCache(from: cache, validationDate: Date())
                updateActivationInfo(from: lk)
                status = .activated
                return true
            } else {
                // Key was revoked, expired, or disabled
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
            let instanceName = "\(label) (\(hardwareId.prefix(8)))"
            let activation = try await LemonSqueezyAPIClient.activate(
                key: key,
                instanceName: instanceName
            )

            guard let instance = activation.instance else {
                throw LSAPIError.apiError("no instance returned")
            }

            // Step 2: Save activation immediately (prevents slot leak if validate fails)
            let cache = LicenseCache(
                licenseKey: key,
                activationId: instance.id,
                lastValidationDate: Date(),
                hardwareId: hardwareId
            )
            _ = KeychainStore.save(cache, forKey: cacheKey)

            // Step 3: Update activation info from response
            if let lk = activation.license_key {
                updateActivationInfo(from: lk)
            }

            activationCount = activation.license_key?.activation_usage ?? 1
            status = .activated
        } catch let error as LSAPIError {
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
            case .apiError(let msg):
                errorMessage = msg
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
            try await LemonSqueezyAPIClient.deactivate(
                key: cache.licenseKey,
                instanceId: cache.activationId
            )
        } catch {
            // Best-effort: still remove local data even if API fails
        }

        KeychainStore.delete(forKey: cacheKey)
        activationCount = 0
        _ = checkTrial()  // fall back to trial if still within trial period
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
        trialHoursRemaining = trial.hoursRemaining
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

    private func updateActivationInfo(from licenseKey: LSLicenseKey) {
        activationLimit = licenseKey.activation_limit
        activationCount = licenseKey.activation_usage
    }
}

#endif
