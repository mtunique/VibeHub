//
//  Settings.swift
//  VibeHub
//
//  App settings manager using UserDefaults
//

import Foundation

/// Available notification sounds
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"

    /// The system sound name to use with NSSound, or nil for no sound
    var soundName: String? {
        self == .none ? nil : rawValue
    }
}

/// How the app presents its UI: notch overlay or menu bar popover.
enum DisplayMode: String {
    case auto
    case notch
    case menuBar
}

enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let remoteHosts = "remoteHosts"
        static let expandOnCompletion = "expandOnCompletion"
        static let displayMode = "displayMode"
        static let menuBarShowDetail = "menuBarShowDetail"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    // MARK: - Display Mode

    static var displayMode: DisplayMode {
        get {
            guard let raw = defaults.string(forKey: Keys.displayMode),
                  let mode = DisplayMode(rawValue: raw) else {
                return .auto
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.displayMode)
        }
    }

    // MARK: - Menu Bar Detail

    static var menuBarShowDetail: Bool {
        get {
            if defaults.object(forKey: Keys.menuBarShowDetail) == nil { return false }
            return defaults.bool(forKey: Keys.menuBarShowDetail)
        }
        set { defaults.set(newValue, forKey: Keys.menuBarShowDetail) }
    }

    // MARK: - Onboarding

    static var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Keys.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Keys.hasCompletedOnboarding) }
    }

    // MARK: - Notification Sound

    /// The sound to play when Claude finishes and is ready for input
    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = defaults.string(forKey: Keys.notificationSound),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .pop // Default to Pop
            }
            return sound
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
        }
    }

    // MARK: - Expand on Completion

    /// Whether to expand the notch when Claude finishes processing
    static var expandOnCompletion: Bool {
        get {
            // Default to true if key has never been set
            if defaults.object(forKey: Keys.expandOnCompletion) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.expandOnCompletion)
        }
        set {
            defaults.set(newValue, forKey: Keys.expandOnCompletion)
        }
    }

    // MARK: - Remote Hosts

    static func getRemoteHosts<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = defaults.data(forKey: Keys.remoteHosts) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func setRemoteHosts<T: Encodable>(_ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Keys.remoteHosts)
    }
}
