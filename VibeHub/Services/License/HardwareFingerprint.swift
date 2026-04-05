//
//  HardwareFingerprint.swift
//  VibeHub
//
//  Generates a stable device identifier from hardware serial number
//

import CryptoKit
import Foundation
import IOKit

#if !APP_STORE

enum HardwareFingerprint {
    /// Returns SHA256 hash of the IOPlatformSerialNumber.
    /// Falls back to IOPlatformUUID if serial is unavailable.
    static var deviceId: String {
        let raw = serialNumber ?? platformUUID ?? UUID().uuidString
        let hash = SHA256.hash(data: Data(raw.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Human-readable device label for Polar activation (e.g. "MacBook Pro")
    static var deviceLabel: String {
        Host.current().localizedName ?? "Mac"
    }

    private static var serialNumber: String? {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard platformExpert != 0 else { return nil }
        defer { IOObjectRelease(platformExpert) }

        return IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformSerialNumberKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String
    }

    private static var platformUUID: String? {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard platformExpert != 0 else { return nil }
        defer { IOObjectRelease(platformExpert) }

        return IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String
    }
}

#endif
