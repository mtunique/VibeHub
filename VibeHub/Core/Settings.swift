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

/// When a notification behavior should trigger
enum NotifyMode: String, CaseIterable {
    /// Never trigger
    case never
    /// Only trigger when the session's terminal is NOT in the foreground
    case backgroundOnly
    /// Always trigger regardless of terminal focus
    case always
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
        static let notifyCompletion = "notifyCompletion"
        static let notifyApproval = "notifyApproval"
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

    // MARK: - Expand on Completion (legacy, kept for migration)

    /// Whether to expand the notch when Claude finishes processing
    static var expandOnCompletion: Bool {
        get {
            if defaults.object(forKey: Keys.expandOnCompletion) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.expandOnCompletion)
        }
        set {
            defaults.set(newValue, forKey: Keys.expandOnCompletion)
        }
    }

    // MARK: - Per-Behavior Notification Modes

    /// When to show the completion popup (task finished, waitingForInput)
    /// Default: never
    static var notifyCompletion: NotifyMode {
        get { notifyMode(forKey: Keys.notifyCompletion, default: .never) }
        set { defaults.set(newValue.rawValue, forKey: Keys.notifyCompletion) }
    }

    /// When to show the approval/interaction popup (tool needs permission or input)
    /// Default: backgroundOnly
    static var notifyApproval: NotifyMode {
        get { notifyMode(forKey: Keys.notifyApproval, default: .backgroundOnly) }
        set { defaults.set(newValue.rawValue, forKey: Keys.notifyApproval) }
    }

    private static func notifyMode(forKey key: String, default defaultMode: NotifyMode) -> NotifyMode {
        guard let raw = defaults.string(forKey: key),
              let mode = NotifyMode(rawValue: raw) else {
            return defaultMode
        }
        return mode
    }

    // MARK: - Notify Mode Helpers

    /// Check if a behavior should trigger given current focus state
    static func shouldNotify(_ mode: NotifyMode, isFocused: Bool) -> Bool {
        switch mode {
        case .never: return false
        case .always: return true
        case .backgroundOnly: return !isFocused
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
