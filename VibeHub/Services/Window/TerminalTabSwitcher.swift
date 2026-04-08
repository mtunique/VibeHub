//
//  TerminalTabSwitcher.swift
//  VibeHub
//
//  Switches to the correct terminal tab via AppleScript (Terminal.app, iTerm2, Ghostty)
//

import AppKit
import Carbon
import Foundation

/// Switches to the correct tab in supported terminal applications using AppleScript
struct TerminalTabSwitcher {
    /// Attempt to switch to the tab containing the given session
    /// - Parameters:
    ///   - bundleId: The terminal app's bundle identifier
    ///   - tty: TTY name without /dev/ prefix (e.g. "ttys001")
    ///   - cwd: Working directory of the session (used by Ghostty)
    /// - Returns: true if tab switching was attempted via AppleScript
    static func switchToTab(bundleId: String, tty: String? = nil, cwd: String? = nil) async -> Bool {
        let capability = TerminalAppRegistry.tabSwitchCapability(for: bundleId)
        guard capability == .applescript else { return false }

        let script: String
        switch bundleId {
        case "com.apple.Terminal":
            guard let tty else { return false }
            script = terminalAppScript(tty: "/dev/\(tty)")
        case "com.googlecode.iterm2":
            guard let tty else { return false }
            script = iterm2Script(tty: "/dev/\(tty)")
        case "com.mitchellh.ghostty":
            if let tty {
                // For remote sessions (or any session with a known tty), match via
                // Ghostty child processes to find the correct terminal index.
                if await ghosttyFocusByTTY(tty: tty) { return true }
            }
            guard let cwd else { return false }
            script = ghosttyScript(cwd: cwd)
        default:
            return false
        }

        return await runAppleScript(script)
    }

    // MARK: - AppleScript Templates

    private static func terminalAppScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
    }

    private static func iterm2Script(tty: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select w
                            select t
                            select s
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    }

    private static func ghosttyScript(cwd: String) -> String {
        """
        tell application "Ghostty"
            set matches to every terminal whose working directory contains "\(cwd)"
            if (count of matches) > 0 then
                focus item 1 of matches
            end if
        end tell
        """
    }

    /// Match a Ghostty terminal by TTY using Accessibility API.
    ///
    /// Ghostty's AppleScript API doesn't expose a `tty` property, so we build
    /// a TTY → tab-index mapping from Ghostty's direct child processes.
    /// Each tab spawns a login child with a unique TTY. Sorting children by
    /// start time (lstart) corresponds to the tab order in Ghostty.
    /// We then use AXPress on the matching tab element to switch to it.
    @MainActor
    private static func ghosttyFocusByTTY(tty: String) async -> Bool {
        guard let ghosttyApp = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.mitchellh.ghostty" })
        else { return false }

        let ghosttyPid = Int(ghosttyApp.processIdentifier)

        // Get all Ghostty direct children with tty and start time.
        // Use lstart for sorting since PIDs can be reused and don't reflect creation order.
        guard let psOutput = ProcessExecutor.shared.runSyncOrNil(
            "/bin/ps", arguments: ["-e", "-o", "pid=,ppid=,tty=,lstart="]
        ) else { return false }

        // Parse ps output: "  PID  PPID TTY                STARTED"
        // e.g. "24966  1050 ttys014  Tue Apr  7 20:29:47 2026"
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let df2 = DateFormatter()
        df2.locale = Locale(identifier: "en_US_POSIX")
        df2.dateFormat = "EEE MMM  d HH:mm:ss yyyy"

        struct Child { let pid: Int; let tty: String; let start: Date }
        var ghosttyChildren: [Child] = []

        for line in psOutput.split(separator: "\n") {
            // Split into: pid, ppid, tty, rest(lstart)
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let pid = Int(parts[0]),
                  let ppid = Int(parts[1]),
                  ppid == ghosttyPid
            else { continue }
            let childTTY = String(parts[2])
            guard !childTTY.isEmpty, childTTY != "??" else { continue }
            let dateStr = parts[3].trimmingCharacters(in: .whitespaces)
            guard let date = df.date(from: dateStr) ?? df2.date(from: dateStr) else { continue }
            ghosttyChildren.append(Child(pid: pid, tty: childTTY, start: date))
        }

        // Sort by start time = tab creation order = Ghostty terminal list order
        ghosttyChildren.sort { $0.start < $1.start }

        let shortTTY = tty.replacingOccurrences(of: "/dev/", with: "")
        guard let tabIndex = ghosttyChildren.firstIndex(where: { $0.tty == shortTTY }) else {
            return false
        }

        // Use AXPress on the tab element for reliable switching
        let axApp = AXUIElementCreateApplication(pid_t(ghosttyPid))
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let window = windows.first
        else { return await fallbackGhosttyFocus(tabIndex: tabIndex) }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement]
        else { return await fallbackGhosttyFocus(tabIndex: tabIndex) }

        // Find the tab group and press the correct tab
        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            guard (roleRef as? String) == "AXTabGroup" else { continue }

            var tabsRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXTabsAttribute as CFString, &tabsRef)
            guard let tabs = tabsRef as? [AXUIElement], tabIndex < tabs.count else { break }

            return AXUIElementPerformAction(tabs[tabIndex], kAXPressAction as CFString) == .success
        }

        return await fallbackGhosttyFocus(tabIndex: tabIndex)
    }

    /// Fallback: use AppleScript to focus Ghostty terminal by index
    private static func fallbackGhosttyFocus(tabIndex: Int) async -> Bool {
        let script = """
        tell application "Ghostty"
            set termList to every terminal
            if (count of termList) >= \(tabIndex + 1) then
                focus item \(tabIndex + 1) of termList
            end if
        end tell
        """
        return await runAppleScript(script)
    }

    // MARK: - Execution

    private static func runAppleScript(_ script: String) async -> Bool {
        let process = Process()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            let ok = process.terminationStatus == 0
            if !ok {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? ""
                let msg = "osascript failed: \(errMsg)\n"
                if let fh = FileHandle(forWritingAtPath: "/tmp/vibehub-activator.log") {
                    fh.seekToEndOfFile(); fh.write(msg.data(using: .utf8)!); fh.closeFile()
                }
            }
            return ok
        } catch {
            return false
        }
    }
}
