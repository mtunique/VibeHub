//
//  SettingsWindowController.swift
//  VibeHub
//
//  Opens the system-managed Settings window
//

import AppKit

@MainActor
class SettingsWindowController {
    static let shared = SettingsWindowController()

    func show() {
        // Use the SwiftUI Settings scene — gives native macOS window appearance
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    #if !APP_STORE
    func showLicense() {
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .settingsNavigateToLicense, object: nil)
        }
    }
    #endif
}

extension Notification.Name {
    static let settingsNavigateToLicense = Notification.Name("settingsNavigateToLicense")
}
