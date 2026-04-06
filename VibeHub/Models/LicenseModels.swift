//
//  LicenseModels.swift
//  VibeHub
//
//  License types for LemonSqueezy integration
//

import Foundation

#if !APP_STORE

// MARK: - App State

enum LicenseStatus: String, Codable {
    case locked
    case trial
    case activated
    case validating
}

// MARK: - Trial Data

struct TrialData: Codable {
    let startDate: Date

    static let trialDays = 30

    var hoursRemaining: Int {
        let totalSeconds = TimeInterval(Self.trialDays * 24 * 3600)
        let elapsed = Date().timeIntervalSince(startDate)
        return max(0, Int((totalSeconds - elapsed) / 3600))
    }

    var daysRemaining: Int { hoursRemaining / 24 }

    var isExpired: Bool { hoursRemaining == 0 }
}

// MARK: - Local Cache

struct LicenseCache: Codable {
    let licenseKey: String
    let activationId: String
    let lastValidationDate: Date
    let hardwareId: String
}

// MARK: - LemonSqueezy API Types

struct LSLicenseKey: Decodable {
    let id: Int
    let status: String  // "active", "inactive", "expired", "disabled"
    let key: String
    let activation_limit: Int
    let activation_usage: Int
    let expires_at: String?
}

struct LSInstance: Decodable {
    let id: String
    let name: String
    let created_at: String
}

struct LSValidateResponse: Decodable {
    let valid: Bool
    let error: String?
    let license_key: LSLicenseKey?
    let instance: LSInstance?
}

struct LSActivateResponse: Decodable {
    let activated: Bool
    let error: String?
    let license_key: LSLicenseKey?
    let instance: LSInstance?
}

struct LSDeactivateResponse: Decodable {
    let deactivated: Bool
    let error: String?
}

enum LSAPIError: Error, LocalizedError {
    case invalidKey
    case deviceLimitReached
    case keyRevoked
    case apiError(String)
    case networkError(Error)
    case unexpectedResponse(Int)

    var errorDescription: String? {
        switch self {
        case .invalidKey: return "Invalid license key"
        case .deviceLimitReached: return "Device limit reached"
        case .keyRevoked: return "License key revoked"
        case .apiError(let msg): return msg
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        case .unexpectedResponse(let code): return "Unexpected response: \(code)"
        }
    }
}

#endif
