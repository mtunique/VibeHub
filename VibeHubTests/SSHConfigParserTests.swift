//
//  SSHConfigParserTests.swift
//  VibeHubTests
//
//  Tests for SSHConfigParser.parse() — host parsing, wildcards, deduplication, sorting.
//

@testable import VibeHub
import XCTest

@MainActor
final class SSHConfigParserTests: XCTestCase {

    // MARK: - Basic Parsing

    func testParseEmptyString_returnsNoEntries() {
        let entries = SSHConfigParser.parse("")
        XCTAssertTrue(entries.isEmpty)
    }

    func testParseOnlyComments_returnsNoEntries() {
        let config = """
        # This is a comment
        # Another comment
        """
        XCTAssertTrue(SSHConfigParser.parse(config).isEmpty)
    }

    func testParseBasicHost() {
        let config = """
        Host myserver
            HostName example.com
            User deploy
        """
        let entries = SSHConfigParser.parse(config)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].alias, "myserver")
        XCTAssertEqual(entries[0].hostName, "example.com")
        XCTAssertEqual(entries[0].user, "deploy")
    }

    func testParseHostWithAllFields() {
        let config = """
        Host full-host
            HostName 192.168.1.10
            User admin
            Port 2222
            IdentityFile ~/.ssh/id_rsa
        """
        let entries = SSHConfigParser.parse(config)
        XCTAssertEqual(entries.count, 1)
        let e = entries[0]
        XCTAssertEqual(e.alias, "full-host")
        XCTAssertEqual(e.hostName, "192.168.1.10")
        XCTAssertEqual(e.user, "admin")
        XCTAssertEqual(e.port, 2222)
        XCTAssertNotNil(e.identityFile)
        XCTAssertTrue(e.identityFile?.contains("id_rsa") == true)
    }

    func testParseMultipleHosts() {
        let config = """
        Host alpha
            HostName alpha.example.com
            User alice

        Host beta
            HostName beta.example.com
            User bob
        """
        let entries = SSHConfigParser.parse(config)
        XCTAssertEqual(entries.count, 2)
        let aliases = entries.map { $0.alias }
        XCTAssertTrue(aliases.contains("alpha"))
        XCTAssertTrue(aliases.contains("beta"))
    }

    // MARK: - Wildcard Filtering

    func testWildcardHostIsSkipped() {
        let config = """
        Host *
            ServerAliveInterval 60
        """
        XCTAssertTrue(SSHConfigParser.parse(config).isEmpty)
    }

    func testQuestionMarkPatternIsSkipped() {
        let config = """
        Host dev?
            HostName devserver.example.com
        """
        XCTAssertTrue(SSHConfigParser.parse(config).isEmpty)
    }

    func testNegationPatternIsSkipped() {
        let config = """
        Host !excluded
            HostName excluded.example.com
        """
        XCTAssertTrue(SSHConfigParser.parse(config).isEmpty)
    }

    func testMixedHostsWithWildcard() {
        let config = """
        Host specific
            HostName specific.example.com

        Host *.example.com
            User shared
        """
        let entries = SSHConfigParser.parse(config)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].alias, "specific")
    }

    // MARK: - Deduplication

    func testDuplicateHostAliasKeepsFirst() {
        let config = """
        Host myserver
            HostName first.example.com

        Host myserver
            HostName second.example.com
        """
        let entries = SSHConfigParser.parse(config)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].hostName, "first.example.com")
    }

    // MARK: - Sorting

    func testResultsAreSortedAlphabetically() {
        let config = """
        Host zebra
            HostName z.example.com
        Host apple
            HostName a.example.com
        Host mango
            HostName m.example.com
        """
        let entries = SSHConfigParser.parse(config)
        let aliases = entries.map { $0.alias }
        XCTAssertEqual(aliases, ["apple", "mango", "zebra"])
    }

    func testSortingIsCaseInsensitive() {
        let config = """
        Host Bravo
            HostName b.example.com
        Host alpha
            HostName a.example.com
        """
        let entries = SSHConfigParser.parse(config)
        XCTAssertEqual(entries.first?.alias, "alpha")
    }

    // MARK: - GSSAPI

    func testGSSAPIAuthentication_yes_setsFlag() {
        let config = """
        Host kerb
            HostName kerb.example.com
            GSSAPIAuthentication yes
        """
        let entries = SSHConfigParser.parse(config)
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].useGSSAPI)
    }

    func testGSSAPIAuthentication_no_leavesFlag_false() {
        let config = """
        Host normal
            HostName normal.example.com
            GSSAPIAuthentication no
        """
        let entries = SSHConfigParser.parse(config)
        XCTAssertFalse(entries[0].useGSSAPI)
    }

    func testGSSAPIDelegateCredentials_yes_setsGSSAPI() {
        let config = """
        Host kerb2
            HostName kerb2.example.com
            GSSAPIDelegateCredentials yes
        """
        let entries = SSHConfigParser.parse(config)
        XCTAssertTrue(entries[0].useGSSAPI)
    }

    // MARK: - Inline Comments

    func testInlineCommentIsStripped() {
        let config = """
        Host commented # this is the alias
            HostName example.com # the hostname
        """
        // The alias has a space but inline # comment is stripped
        // "Host commented" - value is "commented" (no #)
        let entries = SSHConfigParser.parse(config)
        // HostName should be "example.com" after stripping comment
        XCTAssertEqual(entries.first?.hostName, "example.com")
    }

    // MARK: - Case Insensitive Keys

    func testKeysAreCaseInsensitive() {
        let config = """
        HOST uppercase
            HOSTNAME upper.example.com
            USER admin
            PORT 22
        """
        let entries = SSHConfigParser.parse(config)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].alias, "uppercase")
        XCTAssertEqual(entries[0].hostName, "upper.example.com")
        XCTAssertEqual(entries[0].user, "admin")
        XCTAssertEqual(entries[0].port, 22)
    }

    // MARK: - Multi-alias Host line

    func testHostLineWithMultipleAliases_createsOneEntryPerAlias() {
        let config = """
        Host alias1 alias2
            HostName shared.example.com
        """
        let entries = SSHConfigParser.parse(config)
        // Both alias1 and alias2 should appear as separate entries
        XCTAssertEqual(entries.count, 2)
        let aliases = entries.map { $0.alias }.sorted()
        XCTAssertEqual(aliases, ["alias1", "alias2"])
        XCTAssertEqual(entries.first { $0.alias == "alias1" }?.hostName, "shared.example.com")
        XCTAssertEqual(entries.first { $0.alias == "alias2" }?.hostName, "shared.example.com")
    }

    // MARK: - Port Parsing

    func testInvalidPortIsNil() {
        let config = """
        Host badport
            HostName example.com
            Port notanumber
        """
        let entries = SSHConfigParser.parse(config)
        XCTAssertNil(entries[0].port)
    }

    func testValidPort() {
        let config = """
        Host porttest
            HostName example.com
            Port 8022
        """
        let entries = SSHConfigParser.parse(config)
        XCTAssertEqual(entries[0].port, 8022)
    }

    // MARK: - SSHConfigEntry

    func testSSHConfigEntryId_equalsAlias() {
        let entry = SSHConfigEntry(alias: "myhost", hostName: nil, user: nil, port: nil, identityFile: nil, useGSSAPI: false)
        XCTAssertEqual(entry.id, "myhost")
    }

    func testSSHConfigEntryEquatable() {
        let e1 = SSHConfigEntry(alias: "host", hostName: "h.com", user: "u", port: 22, identityFile: nil, useGSSAPI: false)
        let e2 = SSHConfigEntry(alias: "host", hostName: "h.com", user: "u", port: 22, identityFile: nil, useGSSAPI: false)
        XCTAssertEqual(e1, e2)
    }
}
