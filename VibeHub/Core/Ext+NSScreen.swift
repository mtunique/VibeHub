//
//  Ext+NSScreen.swift
//  VibeHub
//
//  Extensions for NSScreen to detect notch and built-in display
//

import AppKit

extension NSScreen {
    /// Returns the size of the notch on this screen (pixel-perfect using macOS APIs)
    var notchSize: CGSize {
        // We render a "pill" that should visually match the physical camera housing.
        // On notched Macs, `safeAreaInsets.top` is the best signal for that height.
        // However, some transient menu bar states can inflate it (recording/sharing indicators).
        // `NSStatusBar.system.thickness` is the *content row* height.
        // The visual menu bar background can be slightly taller (varies by macOS version/scale).
        let menuBarRowHeight = NSStatusBar.system.thickness
        let menuBarBackgroundHeight = max(menuBarRowHeight, frame.maxY - visibleFrame.maxY)
        let rawSafeTop = safeAreaInsets.top
        // Goal: match the *visual* menu bar background height.
        // On notched Macs, `safeAreaInsets.top` is typically the menu bar background height (e.g. ~38pt),
        // while `NSStatusBar.system.thickness` is the content row height (e.g. ~24pt).
        // We follow `safeAreaInsets.top` when present, but cap it to avoid transient inflation.
        let effectiveNotchHeight: CGFloat = {
            guard rawSafeTop > 0 else { return menuBarBackgroundHeight }
            return max(menuBarBackgroundHeight, min(rawSafeTop, menuBarBackgroundHeight + 18))
        }()

        guard safeAreaInsets.top > 0 else {
            // Fallback for non-notch displays (matches typical MacBook notch)
            // On external displays (no physical notch) keep a compact pill;
            // height already matches the menu bar via `effectiveNotchHeight`.
            return CGSize(width: 120, height: effectiveNotchHeight)
        }

        let fullWidth = frame.width
        let leftPadding = auxiliaryTopLeftArea?.width ?? 0
        let rightPadding = auxiliaryTopRightArea?.width ?? 0

        guard leftPadding > 0, rightPadding > 0 else {
            // Fallback if auxiliary areas unavailable
            return CGSize(width: 180, height: effectiveNotchHeight)
        }

        // +4 to match boring.notch's calculation for proper alignment
        let computedWidth = fullWidth - leftPadding - rightPadding + 4

        // Guard against transient menu bar layout changes (e.g. screen recording/sharing indicators)
        // that can make auxiliary areas report smaller widths, inflating the derived notch width.
        let maxReasonableWidth = max(CGFloat(200), effectiveNotchHeight * 6)
        let notchWidth = min(computedWidth, maxReasonableWidth)
        return CGSize(width: notchWidth, height: effectiveNotchHeight)
    }

    /// Whether this is the built-in display
    var isBuiltinDisplay: Bool {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return false
        }
        return CGDisplayIsBuiltin(screenNumber) != 0
    }

    /// The built-in display (with notch on newer MacBooks)
    static var builtin: NSScreen? {
        if let builtin = screens.first(where: { $0.isBuiltinDisplay }) {
            return builtin
        }
        return NSScreen.main
    }

    /// Whether this screen has a physical notch (camera housing)
    var hasPhysicalNotch: Bool {
        safeAreaInsets.top > 0
    }
}
