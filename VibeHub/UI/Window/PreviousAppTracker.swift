//
//  PreviousAppTracker.swift
//  VibeHub
//
//  Tracks the most recent non-VibeHub application that has had frontmost
//  status. `NotchWindowController.exitKeyboardMode` uses this to hand
//  focus back to whatever the user was working in before VibeHub grabbed
//  it for chat input.
//
//  We observe `NSWorkspace.didActivateApplicationNotification` globally
//  so the tracked value is always fresh — enter/exit of keyboard mode
//  don't have to be perfectly balanced for restore to work.
//

import AppKit

@MainActor
final class PreviousAppTracker {
    static let shared = PreviousAppTracker()

    /// Most recently activated app, excluding VibeHub itself.
    private var lastApp: NSRunningApplication?

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.bundleIdentifier != Bundle.main.bundleIdentifier
            else { return }
            Task { @MainActor in self?.lastApp = app }
        }

        // Seed from the current frontmost app if it's not us.
        if let current = NSWorkspace.shared.frontmostApplication,
           current.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastApp = current
        }
    }

    /// Activate the tracked previous app if it's still running. Called by
    /// NotchWindowController when exiting keyboard mode with VibeHub still
    /// holding frontmost.
    func restore() {
        guard let app = lastApp, !app.isTerminated else { return }
        app.activate(options: .activateIgnoringOtherApps)
    }
}
