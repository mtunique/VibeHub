# Polar.sh License Key Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add license key activation via Polar.sh so non-App-Store builds require a valid license to use the app.

**Architecture:** New `Services/License/` module with four files (LicenseManager, PolarAPIClient, HardwareFingerprint, KeychainStore). Two new UI views (activation lock screen, settings section). AppDelegate gates startup on license status. All license code is behind `#if !APP_STORE`.

**Tech Stack:** Swift, URLSession (Polar.sh REST API), Security.framework (Keychain), IOKit (hardware fingerprint), SwiftUI

---

## File Structure

**New files:**

| File | Responsibility |
|------|---------------|
| `VibeHub/Services/License/KeychainStore.swift` | Generic Keychain CRUD for Codable values |
| `VibeHub/Services/License/HardwareFingerprint.swift` | SHA256 of IOPlatformSerialNumber |
| `VibeHub/Services/License/PolarAPIClient.swift` | Polar.sh validate/activate/deactivate API calls |
| `VibeHub/Services/License/LicenseManager.swift` | `@MainActor` singleton orchestrating license state |
| `VibeHub/Models/LicenseModels.swift` | LicenseStatus enum, LicenseCache, API request/response types |
| `VibeHub/UI/Views/LicenseActivationView.swift` | Lock screen UI (key input + activate + purchase) |
| `VibeHub/UI/Views/LicenseSettingsView.swift` | Settings section (status, device count, deactivate) |

**Modified files:**

| File | Change |
|------|--------|
| `VibeHub/Core/L10n.swift` | Add license-related localization strings |
| `VibeHub/Core/NotchViewModel.swift` | Add `.license` content type |
| `VibeHub/App/AppDelegate.swift` | Gate startup on LicenseManager validation |
| `VibeHub/UI/Views/NotchView.swift` | Route `.license` content type to LicenseActivationView |
| `VibeHub/UI/Views/NotchMenuView.swift` | Insert LicenseSettingsView section |

---

### Task 1: License Models

**Files:**
- Create: `VibeHub/Models/LicenseModels.swift`

- [ ] **Step 1: Create LicenseModels.swift**

```swift
//
//  LicenseModels.swift
//  VibeHub
//
//  License types for Polar.sh integration
//

import Foundation

#if !APP_STORE

// MARK: - App State

enum LicenseStatus: String, Codable {
    case locked
    case activated
    case validating
}

// MARK: - Local Cache

struct LicenseCache: Codable {
    let licenseKey: String
    let activationId: String
    let lastValidationDate: Date
    let hardwareId: String
}

// MARK: - Polar API Types

struct PolarValidateRequest: Encodable {
    let key: String
    let organization_id: String
    let activation_id: String?
}

struct PolarValidateResponse: Decodable {
    let id: String
    let organization_id: String
    let status: String  // "granted", "revoked", "disabled"
    let key: String
    let usage: Int
    let limit_usage: Int?
    let validations: Int
    let limit_activations: Int?
    let activations: [PolarActivation]?
    let expires_at: String?
}

struct PolarActivateRequest: Encodable {
    let key: String
    let organization_id: String
    let label: String
    let conditions: [String: String]?
}

struct PolarActivateResponse: Decodable {
    let id: String
    let license_key_id: String
    let label: String
    let conditions: [String: String]?
}

struct PolarDeactivateRequest: Encodable {
    let key: String
    let organization_id: String
    let activation_id: String
}

struct PolarActivation: Decodable {
    let id: String
    let label: String
    let conditions: [String: String]?
}

enum PolarAPIError: Error, LocalizedError {
    case invalidKey
    case deviceLimitReached
    case keyRevoked
    case networkError(Error)
    case unexpectedResponse(Int)

    var errorDescription: String? {
        switch self {
        case .invalidKey: return "Invalid license key"
        case .deviceLimitReached: return "Device limit reached"
        case .keyRevoked: return "License key revoked"
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        case .unexpectedResponse(let code): return "Unexpected response: \(code)"
        }
    }
}

#endif
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild -scheme VibeHub -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add VibeHub/Models/LicenseModels.swift
git commit -m "feat(license): add Polar.sh license model types"
```

---

### Task 2: Keychain Store

**Files:**
- Create: `VibeHub/Services/License/KeychainStore.swift`

- [ ] **Step 1: Create KeychainStore.swift**

```swift
//
//  KeychainStore.swift
//  VibeHub
//
//  Keychain CRUD for license data
//

import Foundation
import Security

#if !APP_STORE

enum KeychainStore {
    private static let service = "com.vibehub.license"

    static func save<T: Encodable>(_ value: T, forKey key: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

#endif
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild -scheme VibeHub -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add VibeHub/Services/License/KeychainStore.swift
git commit -m "feat(license): add Keychain store for license data"
```

---

### Task 3: Hardware Fingerprint

**Files:**
- Create: `VibeHub/Services/License/HardwareFingerprint.swift`

- [ ] **Step 1: Create HardwareFingerprint.swift**

```swift
//
//  HardwareFingerprint.swift
//  VibeHub
//
//  Generates a stable device identifier from hardware serial number
//

import CryptoKit
import Foundation
import IOKit

#if !APP_STORE

enum HardwareFingerprint {
    /// Returns SHA256 hash of the IOPlatformSerialNumber.
    /// Falls back to IOPlatformUUID if serial is unavailable.
    static var deviceId: String {
        let raw = serialNumber ?? platformUUID ?? UUID().uuidString
        let hash = SHA256.hash(data: Data(raw.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Human-readable device label for Polar activation (e.g. "MacBook Pro")
    static var deviceLabel: String {
        Host.current().localizedName ?? "Mac"
    }

    private static var serialNumber: String? {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard platformExpert != 0 else { return nil }
        defer { IOObjectRelease(platformExpert) }

        return IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformSerialNumberKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String
    }

    private static var platformUUID: String? {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard platformExpert != 0 else { return nil }
        defer { IOObjectRelease(platformExpert) }

        return IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String
    }
}

#endif
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild -scheme VibeHub -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add VibeHub/Services/License/HardwareFingerprint.swift
git commit -m "feat(license): add hardware fingerprint generator"
```

---

### Task 4: Polar API Client

**Files:**
- Create: `VibeHub/Services/License/PolarAPIClient.swift`

- [ ] **Step 1: Create PolarAPIClient.swift**

```swift
//
//  PolarAPIClient.swift
//  VibeHub
//
//  Polar.sh public customer portal API client
//

import Foundation

#if !APP_STORE

enum PolarAPIClient {
    private static let baseURL = "https://api.polar.sh/v1/customer-portal/license-keys"

    // TODO: Replace with actual Polar.sh organization ID after product setup
    static let organizationId = "REPLACE_WITH_ORG_ID"

    // TODO: Replace with actual Polar.sh checkout URL after product setup
    static let checkoutURL = "https://polar.sh/REPLACE_WITH_CHECKOUT_URL"

    // MARK: - Validate

    static func validate(key: String, activationId: String?) async throws -> PolarValidateResponse {
        let url = URL(string: "\(baseURL)/validate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = PolarValidateRequest(
            key: key,
            organization_id: organizationId,
            activation_id: activationId
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse

        switch httpResponse.statusCode {
        case 200:
            return try JSONDecoder().decode(PolarValidateResponse.self, from: data)
        case 404:
            throw PolarAPIError.invalidKey
        case 422:
            throw PolarAPIError.invalidKey
        default:
            throw PolarAPIError.unexpectedResponse(httpResponse.statusCode)
        }
    }

    // MARK: - Activate

    static func activate(key: String, hardwareId: String, label: String) async throws -> PolarActivateResponse {
        let url = URL(string: "\(baseURL)/activate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = PolarActivateRequest(
            key: key,
            organization_id: organizationId,
            label: label,
            conditions: ["hardware_id": hardwareId]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse

        switch httpResponse.statusCode {
        case 200:
            return try JSONDecoder().decode(PolarActivateResponse.self, from: data)
        case 403:
            throw PolarAPIError.deviceLimitReached
        case 404, 422:
            throw PolarAPIError.invalidKey
        default:
            throw PolarAPIError.unexpectedResponse(httpResponse.statusCode)
        }
    }

    // MARK: - Deactivate

    static func deactivate(key: String, activationId: String) async throws {
        let url = URL(string: "\(baseURL)/deactivate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = PolarDeactivateRequest(
            key: key,
            organization_id: organizationId,
            activation_id: activationId
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse

        guard (200...299).contains(httpResponse.statusCode) else {
            throw PolarAPIError.unexpectedResponse(httpResponse.statusCode)
        }
    }
}

#endif
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild -scheme VibeHub -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add VibeHub/Services/License/PolarAPIClient.swift
git commit -m "feat(license): add Polar.sh API client"
```

---

### Task 5: License Manager

**Files:**
- Create: `VibeHub/Services/License/LicenseManager.swift`

- [ ] **Step 1: Create LicenseManager.swift**

```swift
//
//  LicenseManager.swift
//  VibeHub
//
//  Orchestrates license validation, activation, and state
//

import Foundation

#if !APP_STORE

@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    @Published var status: LicenseStatus = .locked
    @Published var errorMessage: String?
    @Published var activationCount: Int = 0
    @Published var activationLimit: Int = 3

    private let cacheKey = "license_cache"
    private let offlineGraceDays: TimeInterval = 7 * 24 * 60 * 60  // 7 days

    private init() {}

    // MARK: - Startup Validation

    /// Called at app launch. Returns true if the app should proceed, false if locked.
    func validateOnStartup() async -> Bool {
        guard let cache = KeychainStore.load(LicenseCache.self, forKey: cacheKey) else {
            status = .locked
            return false
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
            status = .locked
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
            status = .locked
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
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild -scheme VibeHub -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (will fail until L10n strings are added — that's OK, we'll add them in Task 6)

- [ ] **Step 3: Commit**

```bash
git add VibeHub/Services/License/LicenseManager.swift
git commit -m "feat(license): add LicenseManager singleton"
```

---

### Task 6: Localization Strings

**Files:**
- Modify: `VibeHub/Core/L10n.swift`

- [ ] **Step 1: Add license strings to L10n.swift**

Add this section before the closing `}` of the `L10n` enum, after the existing "Welcome / Onboarding" section:

```swift
    // MARK: - License

    static var license: String { isChinese ? "许可证" : "License" }
    static var licenseActivated: String { isChinese ? "已激活" : "Activated" }
    static var licenseLocked: String { isChinese ? "需要激活" : "Activation Required" }
    static var licenseLockedTitle: String { isChinese ? "VibeHub 需要许可证" : "VibeHub Requires a License" }
    static var licenseLockedSubtitle: String { isChinese ? "请输入许可证密钥以继续使用" : "Enter your license key to continue" }
    static var licenseKeyPlaceholder: String { isChinese ? "许可证密钥" : "License key" }
    static var licenseActivate: String { isChinese ? "激活" : "Activate" }
    static var licensePurchase: String { isChinese ? "购买" : "Purchase" }
    static var licenseActivating: String { isChinese ? "激活中…" : "Activating..." }
    static var licenseManage: String { isChinese ? "管理许可证" : "Manage License" }
    static var licenseDeactivateDevice: String { isChinese ? "取消激活此设备" : "Deactivate This Device" }
    static var licenseKeyInvalid: String { isChinese ? "许可证密钥无效，请检查后重试" : "Invalid license key. Please check and try again." }
    static var licenseDeviceLimit: String { isChinese ? "已达到设备数量上限，请在其他设备上取消激活" : "Device limit reached. Deactivate another device first." }
    static var licenseKeyRevoked: String { isChinese ? "此许可证已被撤销，请联系支持" : "This license has been revoked. Contact support." }
    static var licenseNetworkError: String { isChinese ? "无法连接验证服务器，请检查网络" : "Cannot reach license server. Check your network." }
    static func licenseDeviceCount(_ current: Int, _ limit: Int) -> String {
        isChinese ? "设备：\(current)/\(limit)" : "Devices: \(current)/\(limit)"
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild -scheme VibeHub -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add VibeHub/Core/L10n.swift
git commit -m "feat(license): add localization strings for license UI"
```

---

### Task 7: License Activation View (Lock Screen)

**Files:**
- Create: `VibeHub/UI/Views/LicenseActivationView.swift`

- [ ] **Step 1: Create LicenseActivationView.swift**

```swift
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
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild -scheme VibeHub -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add VibeHub/UI/Views/LicenseActivationView.swift
git commit -m "feat(license): add license activation lock screen view"
```

---

### Task 8: License Settings View

**Files:**
- Create: `VibeHub/UI/Views/LicenseSettingsView.swift`

- [ ] **Step 1: Create LicenseSettingsView.swift**

```swift
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
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild -scheme VibeHub -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add VibeHub/UI/Views/LicenseSettingsView.swift
git commit -m "feat(license): add license settings view for menu"
```

---

### Task 9: Wire Into NotchViewModel and NotchView

**Files:**
- Modify: `VibeHub/Core/NotchViewModel.swift:28-49` (NotchContentType enum)
- Modify: `VibeHub/UI/Views/NotchView.swift:450-480` (contentView)

- [ ] **Step 1: Add `.license` to NotchContentType**

In `VibeHub/Core/NotchViewModel.swift`, add the license case to the `NotchContentType` enum. Add it inside `#if !APP_STORE` block:

Find:
```swift
    case onboarding
    #if APP_STORE
    case welcome
    #endif
```

Replace with:
```swift
    case onboarding
    #if APP_STORE
    case welcome
    #else
    case license
    #endif
```

And in the `id` computed property, find:
```swift
        case .onboarding: return "onboarding"
        #if APP_STORE
        case .welcome: return "welcome"
        #endif
```

Replace with:
```swift
        case .onboarding: return "onboarding"
        #if APP_STORE
        case .welcome: return "welcome"
        #else
        case .license: return "license"
        #endif
```

- [ ] **Step 2: Add license size to openedSize**

In `NotchViewModel.swift`, find:
```swift
        case .onboarding:
            return CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: 440
            )
        #if APP_STORE
        case .welcome:
```

Replace with:
```swift
        case .onboarding:
            return CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: 440
            )
        #if APP_STORE
        case .welcome:
```

Add before the `#if APP_STORE` block:
```swift
        #if !APP_STORE
        case .license:
            return CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: 420
            )
        #endif
```

So it becomes:
```swift
        case .onboarding:
            return CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: 440
            )
        #if !APP_STORE
        case .license:
            return CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: 420
            )
        #endif
        #if APP_STORE
        case .welcome:
```

- [ ] **Step 3: Route `.license` in contentView**

In `VibeHub/UI/Views/NotchView.swift`, find:
```swift
            case .onboarding:
                OnboardingView(viewModel: viewModel)
            #if APP_STORE
            case .welcome:
                OnboardingView(viewModel: viewModel)
            #endif
```

Replace with:
```swift
            case .onboarding:
                OnboardingView(viewModel: viewModel)
            #if APP_STORE
            case .welcome:
                OnboardingView(viewModel: viewModel)
            #else
            case .license:
                LicenseActivationView(licenseManager: LicenseManager.shared)
            #endif
```

- [ ] **Step 4: Verify it compiles**

Run: `xcodebuild -scheme VibeHub -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add VibeHub/Core/NotchViewModel.swift VibeHub/UI/Views/NotchView.swift
git commit -m "feat(license): wire license content type into notch UI"
```

---

### Task 10: Wire Into Settings Menu

**Files:**
- Modify: `VibeHub/UI/Views/NotchMenuView.swift:96-99`

- [ ] **Step 1: Add license section to NotchMenuView**

In `VibeHub/UI/Views/NotchMenuView.swift`, find the remote row and the divider after it:

```swift
            MenuRow(
                icon: "network",
                label: L10n.remote
            ) {
                viewModel.contentType = .remote
            }

            Divider()
                .background(Color.white.opacity(0.08))
                .padding(.vertical, 4)
```

Replace with:
```swift
            MenuRow(
                icon: "network",
                label: L10n.remote
            ) {
                viewModel.contentType = .remote
            }

            #if !APP_STORE
            LicenseSettingsView(licenseManager: LicenseManager.shared)
            #endif

            Divider()
                .background(Color.white.opacity(0.08))
                .padding(.vertical, 4)
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild -scheme VibeHub -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add VibeHub/UI/Views/NotchMenuView.swift
git commit -m "feat(license): add license section to settings menu"
```

---

### Task 11: Wire Into AppDelegate Startup

**Files:**
- Modify: `VibeHub/App/AppDelegate.swift:50-128`

- [ ] **Step 1: Add license validation to startup**

In `VibeHub/App/AppDelegate.swift`, find the `applicationDidFinishLaunching` method. After the onboarding check, add license validation. Find:

```swift
        if AppSettings.hasCompletedOnboarding {
            startDisplayMode()
        } else {
            // Show standalone onboarding window before any display mode
            onboardingWindow = OnboardingWindowController()
            onboardingWindow?.show { [weak self] in
                self?.onboardingWindow = nil
                self?.startDisplayMode()
            }
        }
```

Replace with:
```swift
        if AppSettings.hasCompletedOnboarding {
            startDisplayMode()
            #if !APP_STORE
            validateLicenseOnStartup()
            #endif
        } else {
            // Show standalone onboarding window before any display mode
            onboardingWindow = OnboardingWindowController()
            onboardingWindow?.show { [weak self] in
                self?.onboardingWindow = nil
                self?.startDisplayMode()
                #if !APP_STORE
                self?.validateLicenseOnStartup()
                #endif
            }
        }
```

- [ ] **Step 2: Add the validateLicenseOnStartup method**

Add this method to AppDelegate, after the `startDisplayMode()` method:

```swift
    #if !APP_STORE
    private func validateLicenseOnStartup() {
        Task { @MainActor in
            let isValid = await LicenseManager.shared.validateOnStartup()
            if !isValid {
                // Show license activation screen
                if let vm = windowController?.viewModel {
                    vm.notchOpen(reason: .boot)
                    vm.contentType = .license
                }
            }
        }
    }
    #endif
```

- [ ] **Step 3: Add an observer for license status changes**

In the same `applicationDidFinishLaunching` method, after the `RemoteManager.shared.startup()` line, add:

```swift
        #if !APP_STORE
        // Watch for license deactivation to lock the UI
        LicenseManager.shared.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newStatus in
                if newStatus == .locked {
                    if let vm = self?.windowController?.viewModel {
                        vm.notchOpen(reason: .boot)
                        vm.contentType = .license
                    }
                }
            }
            .store(in: &licenseCancellables)
        #endif
```

Also add the cancellables storage. At the top of AppDelegate, after the existing properties, add:

```swift
    #if !APP_STORE
    private var licenseCancellables = Set<AnyCancellable>()
    #endif
```

And add `import Combine` at the top if not already present (it's not currently imported in AppDelegate).

- [ ] **Step 4: Verify it compiles**

Run: `xcodebuild -scheme VibeHub -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add VibeHub/App/AppDelegate.swift
git commit -m "feat(license): gate app startup on license validation"
```

---

### Task 12: Prevent Closing License Screen

**Files:**
- Modify: `VibeHub/Core/NotchViewModel.swift`

- [ ] **Step 1: Block notchClose when license is locked**

In `NotchViewModel.swift`, modify the `notchClose()` method. Find:

```swift
    func notchClose() {
        // Save chat session before closing if in chat mode
        if case .chat(let session) = contentType {
            currentChatSession = session
        }
        status = .closed
        contentType = .instances
    }
```

Replace with:
```swift
    func notchClose() {
        #if !APP_STORE
        // Prevent closing the license activation screen
        if case .license = contentType {
            return
        }
        #endif
        // Save chat session before closing if in chat mode
        if case .chat(let session) = contentType {
            currentChatSession = session
        }
        status = .closed
        contentType = .instances
    }
```

- [ ] **Step 2: Also guard notchOpen from overriding license screen**

In `NotchViewModel.swift`, modify `notchOpen()`. Find:

```swift
    func notchOpen(reason: NotchOpenReason = .unknown) {
        openReason = reason
        status = .opened

        #if APP_STORE
        // Don't override welcome screen with other content
        if case .welcome = contentType { return }
        #endif
```

Replace with:
```swift
    func notchOpen(reason: NotchOpenReason = .unknown) {
        openReason = reason
        status = .opened

        #if APP_STORE
        // Don't override welcome screen with other content
        if case .welcome = contentType { return }
        #else
        // Don't override license activation screen with other content
        if case .license = contentType, reason != .boot { return }
        #endif
```

- [ ] **Step 3: Verify it compiles**

Run: `xcodebuild -scheme VibeHub -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add VibeHub/Core/NotchViewModel.swift
git commit -m "feat(license): prevent dismissing license lock screen"
```

---

### Task 13: Auto-dismiss Lock Screen on Activation

**Files:**
- Modify: `VibeHub/App/AppDelegate.swift`

The observer added in Task 11 already watches for status changes. We need to handle the `activated` case to dismiss the lock screen.

- [ ] **Step 1: Update the license status observer**

In `AppDelegate.swift`, find the sink closure we added in Task 11:

```swift
            .sink { [weak self] newStatus in
                if newStatus == .locked {
                    if let vm = self?.windowController?.viewModel {
                        vm.notchOpen(reason: .boot)
                        vm.contentType = .license
                    }
                }
            }
```

Replace with:
```swift
            .sink { [weak self] newStatus in
                guard let vm = self?.windowController?.viewModel else { return }
                switch newStatus {
                case .locked:
                    vm.notchOpen(reason: .boot)
                    vm.contentType = .license
                case .activated:
                    if case .license = vm.contentType {
                        vm.contentType = .instances
                        vm.notchClose()
                        // Perform boot animation after successful activation
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            vm.performBootAnimation()
                        }
                    }
                case .validating:
                    break
                }
            }
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild -scheme VibeHub -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add VibeHub/App/AppDelegate.swift
git commit -m "feat(license): auto-dismiss lock screen on successful activation"
```

---

### Task 14: Final Build Verification

- [ ] **Step 1: Full clean build**

Run: `xcodebuild -scheme VibeHub -configuration Debug clean build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 2: Verify all new files are tracked**

Run: `git status`
Expected: All new files committed, working tree clean.

- [ ] **Step 3: Final commit (if any remaining changes)**

Only if there are uncommitted fixes from build errors.

---

## Post-Implementation Notes

Before the feature is fully functional, you need to:

1. **Create a Polar.sh product** — Set up a one-time purchase product with license key benefit (activation limit = 3)
2. **Update PolarAPIClient constants** — Replace `REPLACE_WITH_ORG_ID` and `REPLACE_WITH_CHECKOUT_URL` with actual values from Polar.sh dashboard
3. **Test the full flow** — Purchase → receive key → enter in app → activate → validate on restart → deactivate
