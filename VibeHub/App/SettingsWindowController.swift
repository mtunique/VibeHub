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

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = L10n.isChinese ? "Vibe Hub 设置" : "Vibe Hub Settings"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.toolbarStyle = .unified
        w.isOpaque = false
        w.backgroundColor = .clear

        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        w.toolbar = toolbar

        w.isReleasedWhenClosed = false

        // Use NSVisualEffectView as the base for behind-window blur
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .sidebar
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        w.contentView = visualEffectView

        let hostingView = NSHostingView(
            rootView: SettingsContentView()
                .frame(width: 680, height: 520)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
        ])

        // Center on the screen where the mouse cursor is.
        // Use setFrame to enforce size after contentViewController may have resized the window.
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        let size = NSSize(width: 680, height: 520)
        if let visibleFrame = screen?.visibleFrame {
            let x = visibleFrame.midX - size.width / 2
            let y = visibleFrame.midY - size.height / 2
            w.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        }

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
