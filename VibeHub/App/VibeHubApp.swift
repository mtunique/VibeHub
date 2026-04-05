//
//  VibeHubApp.swift
//  VibeHub
//
//  Dynamic Island for monitoring Claude Code instances
//

import SwiftUI

@main
struct VibeHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // We use a completely custom window for the notch overlay
        Settings {
            SettingsContentView()
                .frame(minWidth: 680, minHeight: 480)
        }
    }
}
