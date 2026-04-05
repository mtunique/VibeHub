# Polar.sh License Key Integration Design

## Overview

Integrate Polar.sh as the payment and license management backend for VibeHub, distributed outside the Mac App Store. Users must purchase a license key via Polar.sh and activate it in-app before using the application.

## Pricing Model

- **One-time purchase** (买断制)
- License key generated and delivered by Polar.sh upon purchase
- No subscription, no recurring billing

## License States

```
locked ──(activate)──> activated
```

- **locked** — No valid license. App shows activation UI, all functionality disabled.
- **activated** — Valid license verified. App functions normally.

## Startup Flow

```
App Launch
  → Read Keychain for stored license data
  │
  ├─ Has license key
  │   → POST /v1/customer-portal/license-keys/validate
  │   ├─ Success → Update cache, launch normally
  │   └─ Failure (network error)
  │       → Check local cache (lastValidationDate)
  │       ├─ Within 7 days → Launch normally
  │       └─ Expired → Show locked UI
  │
  └─ No license key
      → Show locked UI
```

## Device Limit

- Maximum **3 devices** per license key
- Enforced via Polar.sh activation API (`limit` parameter)
- Each device identified by `SHA256(IOPlatformSerialNumber)`
- Users can deactivate a device from settings to free up a slot

## Components

### 1. LicenseManager

- `@MainActor` singleton, publishes license state for SwiftUI binding
- Orchestrates startup validation, activation, and deactivation
- Exposes `licenseStatus: LicenseStatus` as `@Published`

```swift
enum LicenseStatus {
    case locked
    case activated
    case validating  // transient, during API call
}
```

### 2. PolarAPIClient

Encapsulates Polar.sh public API calls using `URLSession`. No authentication required (public customer portal endpoints).

| Operation | Endpoint | Key Parameters |
|-----------|----------|---------------|
| Validate | `POST /v1/customer-portal/license-keys/validate` | `key`, `organization_id`, `activation_id` |
| Activate | `POST /v1/customer-portal/license-keys/activate` | `key`, `organization_id`, `label` (device name), `conditions` (`{"hardware_id": "sha256..."}`) |
| Deactivate | `POST /v1/customer-portal/license-keys/deactivate` | `key`, `organization_id`, `activation_id` |

### 3. HardwareFingerprint

Generates a stable, unique device identifier:

```swift
SHA256(IOPlatformSerialNumber)
```

Retrieved via `IOServiceGetMatchingService` + `IORegistryEntryCreateCFProperty`. The hash is sent as a condition during activation — never the raw serial number.

### 4. KeychainStore

Stores license data in macOS Keychain under a service-specific key.

```swift
struct LicenseCache: Codable {
    let licenseKey: String
    let activationId: String
    let lastValidationDate: Date
    let hardwareId: String
}
```

Keychain is preferred over UserDefaults because:
- Persists across app reinstalls
- Not trivially editable via `defaults` command
- Encrypted at rest by macOS

## UI Changes

### Locked UI (new view)

Replaces the entire notch/menu bar content when `licenseStatus == .locked`:

- License key text input field
- "Activate" button — calls activate API
- "Purchase" button — opens Polar.sh checkout URL via `NSWorkspace.shared.open`
- Error messages for: invalid key, device limit reached, network error

### Settings Menu (NotchMenuView modification)

New "License" section:

**When activated:**
- Status: "Activated" with checkmark
- Partially masked key display (e.g., `XXXX-XXXX-...-AB12`)
- Device count (e.g., "2/3 devices")
- "Deactivate This Device" button

### Error Messages

| Scenario | Message |
|----------|---------|
| Invalid key | 许可证密钥无效，请检查后重试 |
| Device limit | 已达到设备数量上限（3/3），请在其他设备上取消激活 |
| Network error | 无法连接验证服务器，请检查网络 |
| Key revoked | 此许可证已被撤销，请联系支持 |

## File Structure

New files to create:

```
VibeHub/
  Services/
    License/
      LicenseManager.swift      — State management singleton
      PolarAPIClient.swift      — Polar.sh API wrapper
      HardwareFingerprint.swift — Device ID generation
      KeychainStore.swift       — Keychain CRUD operations
  Models/
    LicenseModels.swift         — LicenseStatus, LicenseCache, API types
  UI/
    Views/
      LicenseActivationView.swift — Locked UI
      LicenseSettingsView.swift   — Settings section
```

Modified files:

```
VibeHub/App/AppDelegate.swift        — Inject LicenseManager into startup
VibeHub/Core/NotchViewModel.swift    — Gate content on license status
VibeHub/UI/Views/NotchMenuView.swift — Add license settings section
VibeHub/UI/Views/NotchView.swift     — Show locked view when unlicensed
```

## Polar.sh Setup Requirements

Before implementation, configure on Polar.sh dashboard:

1. Create organization (if not exists)
2. Create a one-time purchase product for VibeHub
3. Add "License Key" as a benefit to the product
4. Configure license key settings: activation limit = 3
5. Note the `organization_id` for API calls
6. Set up checkout page URL for the "Purchase" button

## Offline Behavior

- On successful validation, cache `lastValidationDate` in Keychain
- If network unavailable on launch, allow usage if cache is within 7 days
- After 7 days without successful validation, show locked UI
- No temporary offline trial (trial feature deferred to future work)

## Security Notes

- Hardware fingerprint is a SHA256 hash — raw serial number never leaves the device
- License key stored in Keychain (encrypted at rest), not UserDefaults
- All API calls use HTTPS
- No API keys or secrets embedded in the app (public endpoints only)
- Determined users can still bypass client-side checks — acceptable trade-off for a developer tool

## Future Work (not in scope)

- Free trial period (requires lightweight backend for hardware_id tracking)
- Webhook integration for order/refund sync
- In-app receipt validation
- Analytics on activation/deactivation patterns
