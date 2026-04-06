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

        // Create window shell immediately (fast)
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

        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        w.toolbar = toolbar

        w.isReleasedWhenClosed = false

        // Center on the screen where the mouse cursor is
        let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main
        if let screen = mouseScreen {
            let screenFrame = screen.visibleFrame
            let windowSize = w.frame.size
            let x = screenFrame.midX - windowSize.width / 2
            let y = screenFrame.midY - windowSize.height / 2
            w.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            w.center()
        }

        // Show window first, then load SwiftUI content on next run loop
        // to avoid blocking the UI while the view tree initializes
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = w

        DispatchQueue.main.async {
            let contentView = SettingsContentView()
                .frame(width: 680, height: 520)
            w.contentViewController = NSHostingController(rootView: contentView)
        }
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
