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
    case trial
    case activated
    case validating
}

// MARK: - Trial Data

struct TrialData: Codable {
    let startDate: Date

    static let trialDays = 7

    var daysRemaining: Int {
        let elapsed = Calendar.current.dateComponents([.day], from: startDate, to: Date()).day ?? 0
        return max(0, Self.trialDays - elapsed)
    }

    var isExpired: Bool { daysRemaining == 0 }
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
    let usage: Int?
    let limit_usage: Int?
    let validations: Int?
    let limit_activations: Int?
    let activation: PolarActivation?   // single activation for the passed activation_id
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
    let meta: [String: String]?
}

struct PolarDeactivateRequest: Encodable {
    let key: String
    let organization_id: String
    let activation_id: String
}

struct PolarActivation: Decodable {
    let id: String
    let label: String
    let meta: [String: String]?
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
