//
//  NotchWindowController.swift
//  VibeHub
//
//  Controls the notch window positioning and lifecycle
//

import AppKit
import Combine
import SwiftUI

class NotchWindowController: NSWindowController {
    static var hasBooted = false

    let viewModel: NotchViewModel
    private let screen: NSScreen
    private var cancellables = Set<AnyCancellable>()
    private var previouslyActiveApp: NSRunningApplication?
    /// Whether the notch panel currently captures mouse events. False means
    /// clicks pass through to whatever is behind the panel.
    private var isNotchInteractive: Bool = false
    
    init(screen: NSScreen) {
        self.screen = screen

        let screenFrame = screen.frame
        let notchSize = screen.notchSize

        // Window covers full width at top, tall enough for largest content (chat view)
        let windowHeight: CGFloat = 750
        let windowFrame = NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.maxY - windowHeight,
            width: screenFrame.width,
            height: windowHeight
        )

        // Device notch rect - positioned at center
        let deviceNotchRect = CGRect(
            x: (screenFrame.width - notchSize.width) / 2,
            y: 0,
            width: notchSize.width,
            height: notchSize.height
        )

        // Create view model
        self.viewModel = NotchViewModel(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenFrame,
            windowHeight: windowHeight,
            hasPhysicalNotch: screen.hasPhysicalNotch
        )

        // Create the window
        let notchWindow = NotchPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: notchWindow)

        // Create the SwiftUI view with pass-through hosting
        let hostingController = NotchViewController(viewModel: viewModel)
        notchWindow.contentViewController = hostingController

        notchWindow.setFrame(windowFrame, display: true)

        // Dynamically toggle mouse event handling based on notch state.
        //
        // Rules:
        // - Closed / popping: ignoresMouseEvents = true (clicks pass through)
        // - Opened via passive notification (.notification / .boot): stay
        //   pass-through — the notch is only a visual cue, it must not capture
        //   mouse events from whatever app the user is working in. Upgrade to
        //   interactive only once the user hovers the notch area (detected via
        //   the global mouse monitor, unaffected by ignoresMouseEvents).
        // - Opened for any other reason (click / hover / interaction / unknown):
        //   ignoresMouseEvents = false (buttons inside panel work).
        //
        // `isInteractive` tracks the current mouse-event routing so the hover
        // upgrade fires at most once per opened session.
        Publishers.CombineLatest(viewModel.$status, viewModel.$openReason)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow] status, reason in
                guard let self = self, let notchWindow = notchWindow else { return }
                switch status {
                case .opened:
                    let passive = (reason == .notification || reason == .boot)
                    self.isNotchInteractive = !passive
                    notchWindow.ignoresMouseEvents = passive
                case .closed, .popping:
                    self.isNotchInteractive = false
                    notchWindow.ignoresMouseEvents = true
                }
            }
            .store(in: &cancellables)

        // Upgrade a passively-opened notch to interactive the moment the user
        // actually hovers over it. isHovering is driven by the global mouse
        // monitor in NotchViewModel.handleMouseMove, so it still fires even
        // while ignoresMouseEvents = true.
        viewModel.$isHovering
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow] _ in
                guard let self = self, let notchWindow = notchWindow else { return }
                guard self.viewModel.status == .opened, !self.isNotchInteractive else { return }
                self.isNotchInteractive = true
                notchWindow.ignoresMouseEvents = false
            }
            .store(in: &cancellables)

        viewModel.$keyboardMode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow] wantsKeyboard in
                guard let notchWindow = notchWindow as? NotchPanel else { return }
                
                if wantsKeyboard {
                    // Entering keyboard mode: save previous app and activate
                    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
                        self?.previouslyActiveApp = NSWorkspace.shared.frontmostApplication
                    }
                    notchWindow.allowsKeyFocus = true
                    NSApp.activate(ignoringOtherApps: true)
                    notchWindow.makeKeyAndOrderFront(nil)
                } else {
                    // Exiting keyboard mode: restore previous app if we are still active
                    notchWindow.allowsKeyFocus = false
                    
                    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
                        if let previousApp = self?.previouslyActiveApp, !previousApp.isTerminated {
                            previousApp.activate(options: .activateIgnoringOtherApps)
                        }
                    }
                    self?.previouslyActiveApp = nil
                }
            }
            .store(in: &cancellables)

        // Start with ignoring mouse events (closed state)
        notchWindow.ignoresMouseEvents = true

        // Perform boot animation after a brief delay (only on first launch)
        if !Self.hasBooted {
            Self.hasBooted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.viewModel.performBootAnimation()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
