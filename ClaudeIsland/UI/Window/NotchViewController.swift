//
//  NotchViewController.swift
//  ClaudeIsland
//
//  Hosts the SwiftUI NotchView in AppKit with click-through support
//

import AppKit
import SwiftUI

/// Custom NSHostingView that only accepts mouse events within the panel bounds.
/// Clicks outside the panel pass through to windows behind.
class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    var hitTestRect: () -> CGRect = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only accept hits within the panel rect
        guard hitTestRect().contains(point) else {
            return nil  // Pass through to windows behind
        }
        return super.hitTest(point)
    }
}

class NotchViewController: NSViewController {
    private let viewModel: NotchViewModel
    private var hostingView: PassThroughHostingView<NotchView>!

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        hostingView = PassThroughHostingView(rootView: NotchView(viewModel: viewModel))

        // Calculate hit-test rect in window coordinates (origin at bottom-left)
        hostingView.hitTestRect = { [weak self] in
            guard let self = self else { return .zero }
            let vm = self.viewModel
            let geometry = vm.geometry
            let screenRect = geometry.screenRect
            let windowHeight = geometry.windowHeight

            // In window coords: y increases upward from window bottom
            // Window bottom is at screenRect.origin.y in screen coords
            // So window-y = screenY - screenRect.origin.y

            switch vm.status {
            case .opened:
                let panelSize = vm.openedSize
                let panelWidth = panelSize.width + 52
                let panelHeight = panelSize.height
                // Panel bottom in window-y: screenY_of_panelBottom - screenRect.origin.y
                // panelBottom_screen = screenRect.maxY - panelHeight
                let panelBottomScreen = screenRect.maxY - panelHeight
                let panelBottomWindow = panelBottomScreen - screenRect.origin.y
                return CGRect(
                    x: (screenRect.width - panelWidth) / 2,
                    y: panelBottomWindow,
                    width: panelWidth,
                    height: panelHeight
                )
            case .closed, .popping:
                let notchRect = geometry.deviceNotchRect
                // Notch bottom in window-y
                let notchBottomScreen = screenRect.maxY - notchRect.height
                let notchBottomWindow = notchBottomScreen - screenRect.origin.y
                return CGRect(
                    x: (screenRect.width - notchRect.width) / 2 - 10,
                    y: notchBottomWindow - 5,
                    width: notchRect.width + 20,
                    height: notchRect.height + 10
                )
            }
        }

        self.view = hostingView
    }
}
