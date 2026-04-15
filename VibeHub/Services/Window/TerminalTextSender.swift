//
//  TerminalTextSender.swift
//  VibeHub
//
//  Sends a line of text into a specific terminal tab via AppleScript.
//  This is the non-tmux fallback for `ChatView.sendToSession`. Historically
//  VibeHub injected characters via TIOCSTI, but Apple restricted that
//  syscall on recent macOS versions so the TIOCSTI path silently fails on
//  many setups and the chat falls through to the clipboard hint.
//
//  This sender reaches each supported terminal through its scripting API
//  and writes text directly into the tab matching the session's TTY. It
//  works without TIOCSTI and without stealing focus from VibeHub.
//

import AppKit
import Foundation

enum TerminalTextSender {

    /// Whether this session's controlling terminal supports AppleScript text
    /// sending (Terminal.app or iTerm2). Used by `ChatView.canSendMessages`
    /// to gate the input bar without attempting a full send.
    @MainActor
    static func canSend(session: SessionState) -> Bool {
        guard let pid = session.pid, session.tty != nil else { return false }
        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let bundleId = terminalBundleId(forProcess: pid, tree: tree) else { return false }
        return bundleId == "com.apple.Terminal" || bundleId == "com.googlecode.iterm2"
    }

    /// Attempt to send `text` to the terminal tab whose tty matches
    /// `session.tty`. Returns `true` on success, `false` if no supported
    /// terminal / tab could be matched (caller should fall back to
    /// clipboard + focus).
    @MainActor
    static func send(text: String, session: SessionState) async -> Bool {
        guard let tty = session.tty, !tty.isEmpty else { return false }
        guard let pid = session.pid else { return false }

        // Resolve the controlling terminal app by walking the process tree.
        let tree = ProcessTreeBuilder.shared.buildTree()
        let bundleId = terminalBundleId(forProcess: pid, tree: tree)

        // Full `/dev/ttysXXX` path — terminals' scripting dictionaries
        // expose the tty property with the `/dev/` prefix.
        let ttyPath = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"

        switch bundleId {
        case "com.apple.Terminal":
            return await runScript(terminalAppScript(ttyPath: ttyPath, text: text))
        case "com.googlecode.iterm2":
            return await runScript(iterm2Script(ttyPath: ttyPath, text: text))
        default:
            // Ghostty / Alacritty / Warp / etc. don't expose a scriptable
            // "write text" API pinned to a specific tty, so we can't safely
            // target the right tab. Caller falls back to clipboard.
            return false
        }
    }

    // MARK: - Terminal bundle resolution

    /// Walk the process tree from `pid` upward and return the first ancestor
    /// whose NSRunningApplication bundle identifier is a known terminal.
    @MainActor
    private static func terminalBundleId(forProcess pid: Int, tree: [Int: ProcessInfo]) -> String? {
        let runningApps = NSWorkspace.shared.runningApplications
        var current = pid
        var depth = 0
        while current > 1 && depth < 20 {
            if let app = runningApps.first(where: { $0.processIdentifier == pid_t(current) }),
               let bundleId = app.bundleIdentifier,
               TerminalAppRegistry.isTerminalBundle(bundleId) {
                return bundleId
            }
            guard let info = tree[current] else {
                // Resolve ppid via sysctl when the process tree snapshot is stale.
                var kinfo = kinfo_proc()
                var size = MemoryLayout<kinfo_proc>.size
                var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(current)]
                if sysctl(&mib, 4, &kinfo, &size, nil, 0) == 0 && size > 0 {
                    current = Int(kinfo.kp_eproc.e_ppid)
                    depth += 1
                    continue
                }
                break
            }
            current = info.ppid
            depth += 1
        }
        return nil
    }

    // MARK: - AppleScript templates

    /// Terminal.app: `do script "text" in tab` writes text into that tab's
    /// stdin followed by a newline. `without activating` prevents focus
    /// stealing — VibeHub stays in front.
    private static func terminalAppScript(ttyPath: String, text: String) -> String {
        let escaped = escape(text)
        return """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(ttyPath)" then
                        do script "\(escaped)" in t
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "not-found"
        """
    }

    /// iTerm2: `write text` on a matched session. Same behavior — writes
    /// to the underlying TTY and submits a newline.
    private static func iterm2Script(ttyPath: String, text: String) -> String {
        let escaped = escape(text)
        return """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(ttyPath)" then
                            tell s to write text "\(escaped)"
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "not-found"
        """
    }

    /// Escape a string for embedding in an AppleScript double-quoted literal.
    /// AppleScript doesn't support many escape sequences; we only need to
    /// guard backslashes and double quotes.
    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - AppleScript runner

    /// Run an AppleScript and return true only when it emits the "ok" sentinel
    /// we use to signal that the matching tab was found and written to.
    @MainActor
    private static func runScript(_ source: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if error != nil {
                    continuation.resume(returning: false)
                    return
                }
                let value = result?.stringValue ?? ""
                continuation.resume(returning: value == "ok")
            }
        }
    }
}
