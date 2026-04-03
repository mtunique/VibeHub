//
//  NotchGeometry.swift
//  ClaudeIsland
//
//  Geometry calculations for the notch
//

import CoreGraphics
import Foundation

/// Pure geometry calculations for the notch
struct NotchGeometry: Sendable {
    let deviceNotchRect: CGRect
    let screenRect: CGRect
    let windowHeight: CGFloat

    /// The notch rect in screen coordinates (for hit testing with global mouse position)
    var notchScreenRect: CGRect {
        CGRect(
            x: screenRect.midX - deviceNotchRect.width / 2,
            y: screenRect.maxY - deviceNotchRect.height,
            width: deviceNotchRect.width,
            height: deviceNotchRect.height
        )
    }

    /// The opened panel rect in screen coordinates for a given size
    func openedScreenRect(for size: CGSize) -> CGRect {
        // Match the actual rendered panel size (tuned to match visual output)
        let width = size.width - 6
        let height = size.height - 30
        return CGRect(
            x: screenRect.midX - width / 2,
            y: screenRect.maxY - height,
            width: width,
            height: height
        )
    }

    /// Comfort margin added around the content width for hit-testing.
    private static let hitTestPadding: CGFloat = 24

    /// Effective hit-test width for the closed notch given the reported content width.
    /// Shared by both `isPointInNotch` (screen-coordinate check) and
    /// `closedHitTestRect` (window-coordinate rect for `PassThroughHostingView`).
    func closedHitTestWidth(contentWidth: CGFloat) -> CGFloat {
        if contentWidth > 0 {
            return contentWidth + Self.hitTestPadding
        }
        return deviceNotchRect.width + Self.hitTestPadding
    }

    /// The closed-state hit-test rect in **window coordinates** (origin at bottom-left).
    /// Used by `PassThroughHostingView` to decide whether to accept or pass-through clicks.
    func closedHitTestRect(contentWidth: CGFloat) -> CGRect {
        let width = closedHitTestWidth(contentWidth: contentWidth)
        return CGRect(
            x: (screenRect.width - width) / 2,
            y: windowHeight - deviceNotchRect.height - 5,
            width: width,
            height: deviceNotchRect.height + 10
        )
    }

    /// Check if a point (in **screen coordinates**) is in the notch area.
    ///
    /// - Parameter contentWidth: The actual rendered closed-content width reported by
    ///   `NotchView` (notch width + expansion for badges/labels/etc.). When non-zero this
    ///   value is used directly so the hit-test region matches the visible content exactly.
    func isPointInNotch(_ point: CGPoint, contentWidth: CGFloat = 0) -> Bool {
        let width = closedHitTestWidth(contentWidth: contentWidth)
        let expandedRect = CGRect(
            x: screenRect.midX - width / 2,
            y: notchScreenRect.minY - 10,
            width: width,
            height: notchScreenRect.height + 20
        )
        return expandedRect.contains(point)
    }

    /// Check if a point is in the opened panel area
    func isPointInOpenedPanel(_ point: CGPoint, size: CGSize) -> Bool {
        openedScreenRect(for: size).contains(point)
    }

    /// Check if a point is outside the opened panel (for closing)
    func isPointOutsidePanel(_ point: CGPoint, size: CGSize) -> Bool {
        !openedScreenRect(for: size).contains(point)
    }
}
