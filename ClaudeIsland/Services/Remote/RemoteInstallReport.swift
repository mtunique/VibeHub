import Foundation

struct RemoteInstallStep: Identifiable, Codable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let command: String
    let ok: Bool
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

struct RemoteInstallReport: Codable, Equatable, Sendable {
    let startedAt: Date
    let finishedAt: Date
    let steps: [RemoteInstallStep]

    var ok: Bool { steps.allSatisfy { $0.ok } }
}
