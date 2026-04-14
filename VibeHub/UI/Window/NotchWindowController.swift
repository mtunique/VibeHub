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
            .sink { [weak notchWindow] wantsKeyboard in
                guard let notchWindow = notchWindow as? NotchPanel else { return }

                if wantsKeyboard {
                    notchWindow.allowsKeyFocus = true
                    NSApp.activate(ignoringOtherApps: true)
                    notchWindow.makeKeyAndOrderFront(nil)
                } else {
                    // Exiting keyboard mode: resign key + restore whichever
                    // non-VibeHub app was frontmost most recently. We keep
                    // that reference on `PreviousAppTracker` instead of
                    // snapshotting on enter — that way every exit path
                    // (onDisappear, contentType change, explicit click
                    // outside, display-mode swap) has a live target to hand
                    // focus back to, even if enter/exit aren't balanced.
                    //
                    // Deliberately no `NSApp.hide` fallback — that would
                    // hide the Settings window alongside the notch.
                    notchWindow.allowsKeyFocus = false
                    if notchWindow.isKeyWindow {
                        notchWindow.resignKey()
                    }
                    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
                        PreviousAppTracker.shared.restore()
                    }
                }
            }
            .store(in: &cancellables)

        // Belt-and-suspenders safety net: whenever the content type leaves
        // `.chat`, force-exit keyboard mode. ChatView's `.onDisappear`
        // already covers the normal case, but this catches any path where
        // SwiftUI doesn't tear down the view cleanly (e.g. animated content
        // swaps inside the notch while the hosting controller persists).
        viewModel.$contentType
            .removeDuplicates { lhs, rhs in
                // Treat any two non-chat cases as "equal" so we only fire
                // the sink on transitions into/out of chat.
                switch (lhs, rhs) {
                case (.chat, .chat): return true
                case (.chat, _), (_, .chat): return false
                default: return true
                }
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak viewModel] contentType in
                if case .chat = contentType { return }
                viewModel?.exitKeyboardMode()
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
