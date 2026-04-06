//
//  SSHForwarderStatusTests.swift
//  VibeHubTests
//
//  Tests for SSHForwarder.Status enum Equatable conformance.
//  Status drives the connection-state UI for remote Claude Code / OpenCode sessions.
//

@testable import VibeHub
import XCTest

@MainActor
final class SSHForwarderStatusTests: XCTestCase {

    // MARK: - Same-case equality

    func testDisconnected_equalsDisconnected() {
        XCTAssertEqual(SSHForwarder.Status.disconnected, .disconnected)
    }

    func testConnecting_equalsConnecting() {
        XCTAssertEqual(SSHForwarder.Status.connecting, .connecting)
    }

    func testConnected_equalsConnected() {
        XCTAssertEqual(SSHForwarder.Status.connected, .connected)
    }

    func testFailed_sameMessage_equal() {
        XCTAssertEqual(SSHForwarder.Status.failed("Permission denied"), .failed("Permission denied"))
    }

    // MARK: - Different-case inequality

    func testFailed_differentMessage_notEqual() {
        XCTAssertNotEqual(SSHForwarder.Status.failed("err1"), .failed("err2"))
    }

    func testDisconnected_notEqual_connecting() {
        XCTAssertNotEqual(SSHForwarder.Status.disconnected, .connecting)
    }

    func testDisconnected_notEqual_connected() {
        XCTAssertNotEqual(SSHForwarder.Status.disconnected, .connected)
    }

    func testDisconnected_notEqual_failed() {
        XCTAssertNotEqual(SSHForwarder.Status.disconnected, .failed("x"))
    }

    func testConnecting_notEqual_connected() {
        XCTAssertNotEqual(SSHForwarder.Status.connecting, .connected)
    }

    func testConnecting_notEqual_failed() {
        XCTAssertNotEqual(SSHForwarder.Status.connecting, .failed("x"))
    }

    func testConnected_notEqual_failed() {
        XCTAssertNotEqual(SSHForwarder.Status.connected, .failed("x"))
    }

    // MARK: - Failed preserves message

    func testFailed_emptyMessage() {
        let s = SSHForwarder.Status.failed("")
        XCTAssertEqual(s, .failed(""))
        XCTAssertNotEqual(s, .failed("something"))
    }

    func testFailed_multilineMessage() {
        let msg = "ssh: connect to host srv port 22:\nConnection refused"
        XCTAssertEqual(SSHForwarder.Status.failed(msg), .failed(msg))
    }
}
