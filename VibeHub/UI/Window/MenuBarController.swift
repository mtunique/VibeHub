import AppKit
import Combine
import SwiftUI

/// Manages an NSStatusItem + NSPopover as an alternative to the notch overlay.
@MainActor
class MenuBarController {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var eventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var legTimer: Timer?
    private var legPhase: Int = 1  // 1 = neutral legs
    private var currentIconColor: NSColor = .white
    private var isAnimating = false

    let viewModel: NotchViewModel
    private let sessionMonitor = ClaudeSessionMonitor.shared

    init() {
        viewModel = NotchViewModel(
            deviceNotchRect: .zero,
            screenRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            windowHeight: 300,
            hasPhysicalNotch: false
        )

        setupStatusItem()
        setupPopover()
        setupEventMonitor()
        observeSessions()
        #if !APP_STORE
        observeLicenseStatus()
        #endif
    }

    nonisolated deinit {
        // tearDown() is called explicitly by WindowManager before releasing.
    }

    func tearDown() {
        stopLegAnimation()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        popover.close()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        cancellables.removeAll()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageTrailing  // text on left, icon on right
            button.image = renderCrabIcon(color: .white, legPhase: 1)
            button.image?.isTemplate = true
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        statusItem = item
    }

    private func setupPopover() {
        popover.behavior = .transient
        popover.animates = true
        let hostingController = NSHostingController(
            rootView: MenuBarContentView(viewModel: viewModel)
                .environmentObject(ClaudeSessionMonitor.shared)
        )
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 400, height: 520)
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: 400, height: 520)
    }

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            if self.popover.isShown {
                self.popover.performClose(nil)
            }
        }
    }

    // MARK: - Session observation (update icon badge)

    #if !APP_STORE
    private func observeLicenseStatus() {
        LicenseManager.shared.$status
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                if status == .locked {
                    self.viewModel.contentType = .license
                    self.showPopover()
                } else if case .activated = status {
                    if self.viewModel.contentType == .license {
                        self.viewModel.contentType = .instances
                        self.popover.performClose(nil)
                    }
                }
            }
            .store(in: &cancellables)
    }
    #endif

    private func observeSessions() {
        sessionMonitor.$instances
            .receive(on: DispatchQueue.main)
            .sink { [weak self] instances in
                self?.updateIcon(instances: instances)
            }
            .store(in: &cancellables)
    }

    private func updateIcon(instances: [SessionState]) {
        guard let button = statusItem?.button else { return }

        #if !APP_STORE
        // When license is locked, show static red icon — don't reflect session activity
        if LicenseManager.shared.status == .locked {
            stopLegAnimation()
            currentIconColor = NSColor.systemRed
            button.image = renderCrabIcon(color: .systemRed, legPhase: 1)
            button.image?.isTemplate = false
            button.title = ""
            return
        }
        #endif

        let hasActive = instances.contains(where: { $0.phase == .processing || $0.phase == .compacting })
        let hasPending = instances.contains(where: {
            if case .waitingForApproval = $0.phase { return true }
            return false
        })

        if hasPending {
            currentIconColor = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
            startLegAnimation()
            if !popover.isShown { showPopover() }
        } else if hasActive {
            currentIconColor = .systemGreen
            startLegAnimation()
        } else {
            currentIconColor = .white
            stopLegAnimation()
            button.image = renderCrabIcon(color: .white, legPhase: 1)
            button.image?.isTemplate = true
        }

        updateDetailText(instances: instances, button: button)
    }

    private func updateDetailText(instances: [SessionState], button: NSStatusBarButton) {
        guard AppSettings.menuBarShowDetail else {
            button.title = ""
            return
        }

        let active = instances
            .filter { $0.phase == .processing || $0.phase == .compacting }
            .sorted(by: { $0.lastActivity > $1.lastActivity })
            .first

        guard let active else {
            // Show session count if any exist
            if !instances.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
                button.attributedTitle = NSAttributedString(string: " \(instances.count) ", attributes: attrs)
            } else {
                button.title = ""
            }
            return
        }

        // Build detail: "project · title" or just "title"
        var parts: [NSAttributedString] = []

        if !active.projectName.isEmpty {
            let project = active.projectName
            parts.append(NSAttributedString(
                string: project,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: NSColor.labelColor.withAlphaComponent(0.5),
                ]
            ))
            parts.append(NSAttributedString(
                string: " · ",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: NSColor.labelColor.withAlphaComponent(0.35),
                ]
            ))
        }

        let title = active.compactDisplayTitle
        parts.append(NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.7),
            ]
        ))

        // Add session count badge
        if instances.count > 1 {
            parts.append(NSAttributedString(
                string: " (\(instances.count))",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
                    .foregroundColor: NSColor.labelColor.withAlphaComponent(0.4),
                ]
            ))
        }

        let result = NSMutableAttributedString(string: " ")  // left padding
        for p in parts { result.append(p) }
        result.append(NSAttributedString(string: " "))  // right padding before icon
        button.attributedTitle = result
    }

    // MARK: - Popover toggle

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    func showPopoverForOnboarding() {
        viewModel.contentType = .onboarding
        guard let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        #if !APP_STORE
        viewModel.contentType = LicenseManager.shared.status == .locked ? .license : .instances
        #else
        viewModel.contentType = .instances
        #endif
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: - Helpers

    private func startLegAnimation() {
        guard !isAnimating else { return }
        isAnimating = true
        legTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.legPhase = (self.legPhase + 1) % 4
                guard let button = self.statusItem?.button else { return }
                button.image = self.renderCrabIcon(color: self.currentIconColor, legPhase: self.legPhase)
                button.image?.isTemplate = false
            }
        }
    }

    private func stopLegAnimation() {
        isAnimating = false
        legTimer?.invalidate()
        legTimer = nil
        legPhase = 1  // Phase 1 = neutral (all zero offsets), matching SwiftUI's non-animated state
    }

    /// Render the crab by snapshotting the actual SwiftUI ClaudeCrabIcon, ensuring pixel-perfect match.
    private func renderCrabIcon(color: NSColor, legPhase: Int = 0) -> NSImage {
        let size: CGFloat = 14
        let swiftUIColor = Color(nsColor: color)

        // Build the same leg offsets as ClaudeCrabIcon
        let legHeightOffsets: [[CGFloat]] = [
            [3, -3, 3, -3], [0, 0, 0, 0],
            [-3, 3, -3, 3], [0, 0, 0, 0],
        ]
        let offsets = legHeightOffsets[legPhase % 4]

        // Use a SwiftUI Canvas identical to ClaudeCrabIcon
        let view = Canvas { context, canvasSize in
            let scale = size / 52.0
            let xOffset = (canvasSize.width - 66 * scale) / 2

            // Antennae
            for x: CGFloat in [0, 60] {
                let p = Path { p in p.addRect(CGRect(x: x, y: 13, width: 6, height: 13)) }
                    .applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
                context.fill(p, with: .color(swiftUIColor))
            }

            // Legs
            for (i, xPos) in ([6, 18, 42, 54] as [CGFloat]).enumerated() {
                let h: CGFloat = 13 + offsets[i]
                let p = Path { p in p.addRect(CGRect(x: xPos, y: 39, width: 6, height: h)) }
                    .applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
                context.fill(p, with: .color(swiftUIColor))
            }

            // Body
            let body = Path { p in p.addRect(CGRect(x: 6, y: 0, width: 54, height: 39)) }
                .applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(body, with: .color(swiftUIColor))

            // Eyes
            for x: CGFloat in [12, 48] {
                let eye = Path { p in p.addRect(CGRect(x: x, y: 13, width: 6, height: 6.5)) }
                    .applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
                context.blendMode = .clear
                context.fill(eye, with: .color(.white))
            }
        }
        .frame(width: size * (66.0 / 52.0), height: size)

        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        guard let cgImage = renderer.cgImage else {
            return NSImage(size: NSSize(width: size, height: size))
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: size * (66.0 / 52.0), height: size))
    }
}
