//
//  TerminalTabSwitcher.swift
//  VibeHub
//
//  Switches to the correct terminal tab via AppleScript (Terminal.app, iTerm2, Ghostty)
//

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
            guard let cwd else { return false }
            script = ghosttyScript(cwd: cwd)
        default:
            return false
        }

        return await runAppleScript(script)
    }

    // MARK: - AppleScript Templates

    /// Escape a string for safe embedding in AppleScript double-quoted strings.
    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func terminalAppScript(tty: String) -> String {
        let safeTTY = escapeForAppleScript(tty)
        return """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(safeTTY)" then
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
        let safeTTY = escapeForAppleScript(tty)
        return """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(safeTTY)" then
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
        let safeCWD = escapeForAppleScript(cwd)
        return """
        tell application "Ghostty"
            set matches to every terminal whose working directory contains "\(safeCWD)"
            if (count of matches) > 0 then
                focus item 1 of matches
            end if
        end tell
        """
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
                if let fh = FileHandle(forWritingAtPath: DebugLog.activatorPath) {
                    fh.seekToEndOfFile(); fh.write(msg.data(using: .utf8)!); fh.closeFile()
                }
            }
            return ok
        } catch {
            return false
        }
    }
}
