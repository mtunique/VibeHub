//
//  SettingsWindowController.swift
//  VibeHub
//
//  Manages a standalone macOS settings window
//

import AppKit
import SwiftUI

@MainActor
class SettingsWindowController: NSObject, NSToolbarDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = SettingsContentView()
            .frame(width: 680, height: 520)
        let hostingController = NSHostingController(rootView: contentView)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = L10n.isChinese ? "VibeHub 设置" : "VibeHub Settings"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.toolbarStyle = .unified

        // Add an empty toolbar to enable the unified titlebar+toolbar area
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        w.toolbar = toolbar

        w.contentViewController = hostingController
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = w
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }

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
