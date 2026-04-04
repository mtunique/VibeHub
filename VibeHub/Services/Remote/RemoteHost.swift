import Foundation

struct RemoteHost: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var user: String?
    var host: String
    /// Optional: if nil, rely on ~/.ssh/config defaults for the host alias.
    var port: Int?
    var identityFile: String?
    /// Whether to use GSSAPI authentication (for jump hosts, Kerberos environments, etc).
    /// When false, uses standard SSH key authentication.
    var useGSSAPI: Bool
    var autoConnect: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        user: String? = nil,
        host: String,
        port: Int? = nil,
        identityFile: String? = nil,
        useGSSAPI: Bool = false,
        autoConnect: Bool = false
    ) {
        self.id = id
        self.name = name
        self.user = user
        self.host = host
        self.port = port
        self.identityFile = identityFile
        self.useGSSAPI = useGSSAPI
        self.autoConnect = autoConnect
    }

    var sshTarget: String {
        if let user, !user.isEmpty {
            return "\(user)@\(host)"
        }
        return host
    }

    /// Used to de-dupe multiple entries pointing at the same remote.
    var hostKey: String {
        let u = (user ?? "").lowercased()
        let h = host.lowercased()
        let p = port.map(String.init) ?? ""
        return "\(u)@\(h):\(p)"
    }
    var namespacePrefix: String { "remote:\(id):" }
    var localSocketPath: String {
        #if APP_STORE
        // Sandbox: use app group container. Shorten the UUID to keep the full
        // path under the 104-byte sun_path limit for Unix domain sockets.
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.mtunique.vibehub"
        ) {
            let shortId = String(id.prefix(8))
            return container.appendingPathComponent("r-\(shortId).sock").path
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibehub", isDirectory: true)
            .appendingPathComponent("remote-\(id).sock")
            .path
    }
    var remoteSocketPath: String { "/tmp/vibehub.sock" }
}
