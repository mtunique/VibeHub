//
//  CmuxSender.swift
//  VibeHub
//
//  Shells out to the cmux CLI to write text into a specific cmux surface.
//
//  cmux (https://cmux.app) is a Unix-socket-controlled terminal multiplexer.
//  Every cmux-hosted terminal exports `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID`
//  into its process environment; the hook script captures those, forwards
//  them via the socket payload, and SessionStore stores them on
//  `SessionState.cmuxWorkspaceId` / `cmuxSurfaceId`.
//
//  At send time we invoke:
//      cmux send --workspace <workspace> --surface <surface> <text>
//  which writes the text into the cmux surface's TTY the same way a keypress
//  would — no TIOCSTI, no focus stealing, no clipboard dance.
//

import Foundation

enum CmuxSender {

    /// Known install locations for the cmux CLI binary. We probe these in
    /// order until one exists. Users can also place the binary on PATH.
    private static let candidateBinaryPaths: [String] = [
        "/Applications/cmux.app/Contents/Resources/bin/cmux",
        "/usr/local/bin/cmux",
        "/opt/homebrew/bin/cmux",
    ]

    /// Write `text` to the cmux surface identified by `surfaceId` (preferred)
    /// or at minimum `workspaceId`, then press Enter so the CLI actually
    /// submits the prompt.
    ///
    /// `cmux send` writes the text into the surface's TTY but does NOT
    /// submit a newline — the user would see the characters but nothing
    /// would happen until they pressed Return. We follow up with
    /// `cmux send-key enter` to finish the turn.
    static func send(text: String, workspaceId: String?, surfaceId: String?) async -> Bool {
        guard workspaceId != nil || surfaceId != nil else { return false }
        guard let binary = await resolveBinary() else { return false }

        let targetArgs: [String] = {
            var out: [String] = []
            if let workspaceId, !workspaceId.isEmpty {
                out.append(contentsOf: ["--workspace", workspaceId])
            }
            if let surfaceId, !surfaceId.isEmpty {
                out.append(contentsOf: ["--surface", surfaceId])
            }
            return out
        }()

        // 1. Write the prompt text.
        do {
            _ = try await ProcessExecutor.shared.run(
                binary,
                arguments: ["send"] + targetArgs + [text]
            )
        } catch {
            return false
        }

        // 2. Press Enter to submit.
        do {
            _ = try await ProcessExecutor.shared.run(
                binary,
                arguments: ["send-key"] + targetArgs + ["enter"]
            )
            return true
        } catch {
            // Text landed but Enter didn't — the user sees their prompt in
            // the input area and can press Return themselves.
            return false
        }
    }

    // MARK: - Binary resolution

    /// Resolve a usable cmux CLI binary, preferring known install paths and
    /// falling back to `/usr/bin/which cmux`. Cached for the lifetime of the
    /// app process since the binary location almost never changes at runtime.
    private static let cache = BinaryCache()

    private static func resolveBinary() async -> String? {
        await cache.resolve()
    }

    /// Caches the resolved cmux binary path. Uses a simple actor to ensure
    /// thread-safe single-resolution semantics. The initial probe runs file
    /// existence checks (cheap) and falls back to `which cmux` (a subprocess).
    /// To avoid blocking the actor's cooperative thread we run the `which`
    /// probe on a detached task and await it.
    private actor BinaryCache {
        private var cached: String??

        func resolve() async -> String? {
            if let cached { return cached }

            let fm = FileManager.default
            for path in candidateBinaryPaths {
                if fm.isExecutableFile(atPath: path) {
                    cached = path
                    return path
                }
            }

            let whichResult: String? = await Task.detached {
                ProcessExecutor.shared.runSyncOrNil(
                    "/usr/bin/which", arguments: ["cmux"]
                )?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.value

            if let whichPath = whichResult,
               !whichPath.isEmpty,
               fm.isExecutableFile(atPath: whichPath) {
                cached = whichPath
                return whichPath
            }

            cached = .some(nil)
            return nil
        }
    }
}
