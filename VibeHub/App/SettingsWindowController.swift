//
//  SettingsWindowController.swift
//  VibeHub
//
//  Manages a standalone macOS settings window
//

import AppKit
import SwiftUI

@MainActor
class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = SettingsContentView()
        let hostingController = NSHostingController(rootView: contentView)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = L10n.isChinese ? "VibeHub 设置" : "VibeHub Settings"
        w.contentViewController = hostingController
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = w
    }

    #if !APP_STORE
    /// Opens settings and navigates directly to the License section
    func showLicense() {
        show()
        NotificationCenter.default.post(name: .settingsNavigateToLicense, object: nil)
    }
    #endif
}

extension Notification.Name {
    static let settingsNavigateToLicense = Notification.Name("settingsNavigateToLicense")
}
