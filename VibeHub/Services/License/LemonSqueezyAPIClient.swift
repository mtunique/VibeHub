//
//  LemonSqueezyAPIClient.swift
//  VibeHub
//
//  LemonSqueezy license API client
//

import Foundation

#if !APP_STORE

enum LemonSqueezyAPIClient {
    private static let baseURL = "https://api.lemonsqueezy.com/v1/licenses"

    static let checkoutURL = "https://mtunique.lemonsqueezy.com/checkout/buy/a8ad63bb-20ec-4c80-9fd1-9847e85386b8"

    // MARK: - Validate

    static func validate(key: String, instanceId: String?) async throws -> LSValidateResponse {
        let url = URL(string: "\(baseURL)/validate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var params = "license_key=\(key)"
        if let instanceId {
            params += "&instance_id=\(instanceId)"
        }
        request.httpBody = params.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse

        guard httpResponse.statusCode == 200 else {
            throw LSAPIError.unexpectedResponse(httpResponse.statusCode)
        }

        let result = try JSONDecoder().decode(LSValidateResponse.self, from: data)
        if let error = result.error {
            throw LSAPIError.apiError(error)
        }
        return result
    }

    // MARK: - Activate

    static func activate(key: String, instanceName: String) async throws -> LSActivateResponse {
        let url = URL(string: "\(baseURL)/activate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = "license_key=\(key)&instance_name=\(instanceName)"
        request.httpBody = params.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse

        guard httpResponse.statusCode == 200 else {
            throw LSAPIError.unexpectedResponse(httpResponse.statusCode)
        }

        let result = try JSONDecoder().decode(LSActivateResponse.self, from: data)
        if let error = result.error {
            if error.contains("limit") {
                throw LSAPIError.deviceLimitReached
            }
            throw LSAPIError.apiError(error)
        }
        guard result.activated else {
            throw LSAPIError.apiError("activation failed")
        }
        return result
    }

    // MARK: - Deactivate

    static func deactivate(key: String, instanceId: String) async throws {
        let url = URL(string: "\(baseURL)/deactivate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = "license_key=\(key)&instance_id=\(instanceId)"
        request.httpBody = params.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse

        guard httpResponse.statusCode == 200 else {
            throw LSAPIError.unexpectedResponse(httpResponse.statusCode)
        }

        let result = try JSONDecoder().decode(LSDeactivateResponse.self, from: data)
        if let error = result.error {
            throw LSAPIError.apiError(error)
        }
    }
}

#endif
