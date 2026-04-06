//
//  RemoteHostTests.swift
//  VibeHubTests
//
//  Tests for RemoteHost value type: computed properties, Equatable, Codable.
//  RemoteHost is the model shared by both the SSH tunnel forwarder and
//  the remote Claude Code / OpenCode session management layer.
//

@testable import VibeHub
import XCTest

@MainActor
final class RemoteHostTests: XCTestCase {

    // MARK: - Helpers

    private func makeHost(
        id: String = "host-id-1",
        name: String = "My Server",
        user: String? = "alice",
        host: String = "example.com",
        port: Int? = nil,
        identityFile: String? = nil,
        useGSSAPI: Bool = false,
        autoConnect: Bool = false
    ) -> RemoteHost {
        RemoteHost(
            id: id,
            name: name,
            user: user,
            host: host,
            port: port,
            identityFile: identityFile,
            useGSSAPI: useGSSAPI,
            autoConnect: autoConnect
        )
    }

    // MARK: - Default Init

    func testDefaultInit_hasExpectedDefaults() {
        let host = RemoteHost(name: "Server", host: "srv.example.com")
        XCTAssertFalse(host.id.isEmpty)
        XCTAssertNil(host.user)
        XCTAssertNil(host.port)
        XCTAssertNil(host.identityFile)
        XCTAssertFalse(host.useGSSAPI)
        XCTAssertFalse(host.autoConnect)
    }

    // MARK: - sshTarget

    func testSSHTarget_withUser() {
        let host = makeHost(user: "bob", host: "remote.example.com")
        XCTAssertEqual(host.sshTarget, "bob@remote.example.com")
    }

    func testSSHTarget_withoutUser() {
        let host = makeHost(user: nil, host: "remote.example.com")
        XCTAssertEqual(host.sshTarget, "remote.example.com")
    }

    func testSSHTarget_withEmptyUser() {
        let host = makeHost(user: "", host: "remote.example.com")
        XCTAssertEqual(host.sshTarget, "remote.example.com")
    }

    // MARK: - hostKey

    func testHostKey_allFieldsPresent() {
        let host = makeHost(user: "Alice", host: "Host.Example.COM", port: 2222)
        XCTAssertEqual(host.hostKey, "alice@host.example.com:2222")
    }

    func testHostKey_noPort() {
        let host = makeHost(user: "alice", host: "example.com", port: nil)
        XCTAssertEqual(host.hostKey, "alice@example.com:")
    }

    func testHostKey_noUser() {
        let host = makeHost(user: nil, host: "example.com", port: 22)
        XCTAssertEqual(host.hostKey, "@example.com:22")
    }

    func testHostKey_isLowercased() {
        let host = makeHost(user: "Bob", host: "SERVER.LOCAL")
        XCTAssertEqual(host.hostKey, "bob@server.local:")
    }

    // MARK: - namespacePrefix

    func testNamespacePrefix_format() {
        let host = makeHost(id: "abc-123")
        XCTAssertEqual(host.namespacePrefix, "remote:abc-123:")
    }

    // MARK: - remoteSocketPath

    func testRemoteSocketPath_isConstant() {
        let host1 = makeHost(id: "id-1")
        let host2 = makeHost(id: "id-2", host: "other.com")
        XCTAssertEqual(host1.remoteSocketPath, "/tmp/vibehub.sock")
        XCTAssertEqual(host2.remoteSocketPath, "/tmp/vibehub.sock")
    }

    // MARK: - localSocketPath

    func testLocalSocketPath_containsId() {
        let host = makeHost(id: "unique-id-42")
        XCTAssertTrue(host.localSocketPath.contains("unique-id-42"))
    }

    func testLocalSocketPath_endsWith_sockExtension() {
        let host = makeHost()
        XCTAssertTrue(host.localSocketPath.hasSuffix(".sock"))
    }

    func testLocalSocketPath_differentPerHost() {
        let h1 = makeHost(id: "aaa")
        let h2 = makeHost(id: "bbb")
        XCTAssertNotEqual(h1.localSocketPath, h2.localSocketPath)
    }

    // MARK: - Equatable

    func testEqual_identicalHosts() {
        let h1 = makeHost(id: "x")
        let h2 = makeHost(id: "x")
        XCTAssertEqual(h1, h2)
    }

    func testNotEqual_differentId() {
        let h1 = makeHost(id: "a")
        let h2 = makeHost(id: "b")
        XCTAssertNotEqual(h1, h2)
    }

    func testNotEqual_differentUser() {
        let h1 = makeHost(id: "x", user: "alice")
        let h2 = makeHost(id: "x", user: "bob")
        XCTAssertNotEqual(h1, h2)
    }

    func testNotEqual_differentPort() {
        let h1 = makeHost(id: "x", port: 22)
        let h2 = makeHost(id: "x", port: 2222)
        XCTAssertNotEqual(h1, h2)
    }

    func testNotEqual_gssapiDiffers() {
        let h1 = makeHost(id: "x", useGSSAPI: false)
        let h2 = makeHost(id: "x", useGSSAPI: true)
        XCTAssertNotEqual(h1, h2)
    }

    // MARK: - Codable

    func testCodable_roundTrip() throws {
        let original = makeHost(
            id: "codable-id",
            name: "Encode Me",
            user: "tester",
            host: "test.example.com",
            port: 4422,
            identityFile: "/home/user/.ssh/id_rsa",
            useGSSAPI: true,
            autoConnect: true
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RemoteHost.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.id, "codable-id")
        XCTAssertEqual(decoded.name, "Encode Me")
        XCTAssertEqual(decoded.user, "tester")
        XCTAssertEqual(decoded.host, "test.example.com")
        XCTAssertEqual(decoded.port, 4422)
        XCTAssertEqual(decoded.identityFile, "/home/user/.ssh/id_rsa")
        XCTAssertTrue(decoded.useGSSAPI)
        XCTAssertTrue(decoded.autoConnect)
    }

    func testCodable_roundTrip_optionalFields_nil() throws {
        let original = makeHost(user: nil, port: nil, identityFile: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RemoteHost.self, from: data)
        XCTAssertNil(decoded.user)
        XCTAssertNil(decoded.port)
        XCTAssertNil(decoded.identityFile)
    }
}
