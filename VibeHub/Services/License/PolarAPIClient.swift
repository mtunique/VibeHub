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
