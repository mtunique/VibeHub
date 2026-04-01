# Compact Notch Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On non-notched screens shrink the default pill width; when sessions are active show a running label in the pill center; always show a session count badge on the far right of the expanded pill.

**Architecture:** All changes are confined to two files — `Ext+NSScreen.swift` for the width constant and `NotchView.swift` for the new UI elements. No new types are introduced.

**Tech Stack:** Swift, SwiftUI, AppKit (macOS 15.6+)

---

### Task 1: Reduce non-notched default pill width

**Files:**
- Modify: `ClaudeIsland/Core/Ext+NSScreen.swift:34`

- [ ] **Step 1: Change fallback width from 224 to 120**

In `Ext+NSScreen.swift`, find the guard block that returns for non-notch displays and change:

```swift
// Before
return CGSize(width: 224, height: effectiveNotchHeight)

// After
return CGSize(width: 120, height: effectiveNotchHeight)
```

- [ ] **Step 2: Commit**

```bash
git add ClaudeIsland/Core/Ext+NSScreen.swift
git commit -m "feat: reduce non-notched fallback pill width from 224 to 120"
```

---

### Task 2: Add active session label and count badge to compact pill

**Files:**
- Modify: `ClaudeIsland/UI/Views/NotchView.swift`

This task adds two computed properties and adjusts `expansionWidth` and `headerRow`.

- [ ] **Step 1: Add `activeSessionLabel` and `sessionCount` computed properties**

Add these two properties in the `// MARK: - Sizing` section of `NotchView`, after the `hasWaitingForInput` property (around line 60):

```swift
/// Label for the most relevant active session (used in compact pill center)
private var activeSessionLabel: String? {
    guard showClosedActivity else { return nil }
    let active = sessionMonitor.instances.first { $0.phase.isWaitingForApproval }
        ?? sessionMonitor.instances.first { $0.phase == .processing || $0.phase == .compacting }
        ?? sessionMonitor.instances.first { $0.phase == .waitingForInput }
    return active?.projectName
}

/// Total number of tracked sessions
private var sessionCount: Int {
    sessionMonitor.instances.count
}
```

Note: `showClosedActivity` is defined later in the file at the `// MARK: - Notch Layout` section — this is fine, Swift resolves properties regardless of declaration order.

- [ ] **Step 2: Widen `expansionWidth` to accommodate the count badge**

The session count badge is 16 pt wide and appears whenever `showClosedActivity && sessionCount > 0`. Add `sessionBadgeWidth` to every branch of `expansionWidth`:

Replace the existing `expansionWidth` computed property (lines ~72–98) with:

```swift
private let countBadgeWidth: CGFloat = 16

/// Extra width for expanding activities (like Dynamic Island)
private var expansionWidth: CGFloat {
    let permissionIndicatorWidth: CGFloat = hasPendingPermission ? 18 : 0
    let sessionBadgeWidth: CGFloat = (showClosedActivity && sessionCount > 0) ? countBadgeWidth : 0

    if activityCoordinator.expandingActivity.show {
        switch activityCoordinator.expandingActivity.type {
        case .claude:
            let baseWidth = 2 * max(0, closedNotchSize.height - 12) + 20
            return baseWidth + permissionIndicatorWidth + sessionBadgeWidth
        case .none:
            break
        }
    }

    if hasPendingPermission {
        return 2 * max(0, closedNotchSize.height - 12) + 20 + permissionIndicatorWidth + sessionBadgeWidth
    }

    if hasWaitingForInput {
        return 2 * max(0, closedNotchSize.height - 12) + 20 + sessionBadgeWidth
    }

    return 0
}
```

- [ ] **Step 3: Replace black spacer with active session label; add count badge**

In `headerRow`, find the `// Closed with activity: black spacer` else-branch and the right-side spinner block, then replace the entire right portion of `headerRow` with the new version.

Current code to replace (the `else` clause for the black spacer + the entire "Right side" block):

```swift
} else {
    // Closed with activity: black spacer (with optional bounce)
    Rectangle()
        .fill(.black)
        .frame(width: closedNotchSize.width - cornerRadiusInsets.closed.top + (isBouncing ? 16 : 0))
}

// Right side - spinner when processing/pending, checkmark when waiting for input
if showClosedActivity {
    if isProcessing || hasPendingPermission {
        ProcessingSpinner()
            .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showClosedActivity)
            .frame(width: viewModel.status == .opened ? 20 : sideWidth)
    } else if hasWaitingForInput {
        // Checkmark for waiting-for-input on the right side
        ReadyForInputIndicatorIcon(size: 14, color: TerminalColors.green)
            .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showClosedActivity)
            .frame(width: viewModel.status == .opened ? 20 : sideWidth)
    }
}
```

Replace with:

```swift
} else {
    // Closed with activity: project label or black spacer (with optional bounce)
    let spacerWidth = closedNotchSize.width - cornerRadiusInsets.closed.top + (isBouncing ? 16 : 0)
    if let label = activeSessionLabel {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(0.6))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: spacerWidth, alignment: .leading)
    } else {
        Rectangle()
            .fill(.black)
            .frame(width: spacerWidth)
    }
}

// Right side - spinner when processing/pending, checkmark when waiting for input
if showClosedActivity {
    if isProcessing || hasPendingPermission {
        ProcessingSpinner()
            .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showClosedActivity)
            .frame(width: viewModel.status == .opened ? 20 : sideWidth)
    } else if hasWaitingForInput {
        ReadyForInputIndicatorIcon(size: 14, color: TerminalColors.green)
            .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showClosedActivity)
            .frame(width: viewModel.status == .opened ? 20 : sideWidth)
    }

    // Session count badge — far right, visible whenever sessions exist
    if viewModel.status != .opened && sessionCount > 0 {
        Text("\(sessionCount)")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(.white.opacity(0.45))
            .frame(width: countBadgeWidth, alignment: .center)
    }
}
```

- [ ] **Step 4: Build and verify**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add ClaudeIsland/UI/Views/NotchView.swift
git commit -m "feat: show active session label and count badge in compact pill"
```
