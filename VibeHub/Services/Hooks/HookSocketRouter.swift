import Foundation

/// Routes permission responses to the correct hook socket server.
///
/// Local sessions use `HookSocketServer.shared`.
/// Remote sessions are namespaced as `remote:<hostId>:...`.
@MainActor
enum HookSocketRouter {
    private static func remoteHostId(from namespaced: String) -> String? {
        guard namespaced.hasPrefix("remote:") else { return nil }
        let rest = namespaced.dropFirst("remote:".count)
        guard let idx = rest.firstIndex(of: ":") else { return nil }
        return String(rest[..<idx])
    }

    private static func server(for namespaced: String) -> HookSocketServer {
        if let hostId = remoteHostId(from: namespaced),
           let remote = RemoteManager.shared.server(for: hostId) {
            return remote
        }
        return HookSocketServer.shared
    }

    static func respondToPermission(toolUseId: String, decision: String, reason: String? = nil, answers: [[String]]? = nil) {
        server(for: toolUseId).respondToPermission(toolUseId: toolUseId, decision: decision, reason: reason, answers: answers)
    }

    static func cancelPendingPermission(toolUseId: String) {
        server(for: toolUseId).cancelPendingPermission(toolUseId: toolUseId)
    }
}
