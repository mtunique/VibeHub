//
//  WindowManager.swift
//  VibeHub
//
//  Manages the notch window and menu bar controller lifecycle
//

import AppKit
import os.log

/// Logger for window management
private let logger = Logger(subsystem: "com.vibehub", category: "Window")

/// Notification posted when the user toggles between notch and menu bar mode.
extension Notification.Name {
    static let displayModeChanged = Notification.Name("com.vibehub.displayModeChanged")
}

class WindowManager {
    private(set) var windowController: NotchWindowController?
    private(set) var menuBarController: MenuBarController?

    /// Set up the initial display mode based on user preference.
    func setup() {
        switchMode(to: AppSettings.displayMode)
    }

    /// Resolve `.auto` to a concrete mode based on whether the screen has a physical notch.
    static func resolveMode(_ mode: DisplayMode) -> DisplayMode {
        guard mode == .auto else { return mode }
        let hasNotch = ScreenSelector.shared.selectedScreen?.hasPhysicalNotch
            ?? NSScreen.main?.hasPhysicalNotch ?? false
        return hasNotch ? .notch : .menuBar
    }

    /// Switch between notch overlay and menu bar popover at runtime.
    func switchMode(to mode: DisplayMode) {
        let mode = Self.resolveMode(mode)
        // Tear down current mode
        if let wc = windowController {
            wc.window?.orderOut(nil)
            wc.window?.close()
            windowController = nil
        }
        if let mbc = menuBarController {
            mbc.tearDown()
            menuBarController = nil
        }

        // Set up new mode
        switch mode {
        case .auto:
            // Already resolved above, won't reach here
            break
        case .notch:
            _ = setupNotchWindow()
        case .menuBar:
            menuBarController = MenuBarController()
        }

        logger.info("Display mode: \(mode.rawValue, privacy: .public)")
    }

    /// Set up or recreate the notch window
    func setupNotchWindow() -> NotchWindowController? {
        guard Self.resolveMode(AppSettings.displayMode) == .notch else { return nil }

        let screenSelector = ScreenSelector.shared
        screenSelector.refreshScreens()

        guard let screen = screenSelector.selectedScreen else {
            logger.warning("No screen found")
            return nil
        }

        if let existingController = windowController {
            existingController.window?.orderOut(nil)
            existingController.window?.close()
            windowController = nil
        }

        windowController = NotchWindowController(screen: screen)
        windowController?.showWindow(nil)

        return windowController
    }
}
