#if !APP_STORE

import AppKit
import Combine
import Foundation
import os.log

private let logger = Logger(subsystem: "com.vibehub", category: "NowPlaying")

/// Polls Spotify via AppleScript for now-playing info.
actor NowPlayingService {
    static let shared = NowPlayingService()

    private let executor = ProcessExecutor.shared

    let stateSubject = CurrentValueSubject<NowPlayingState, Never>(.empty)

    /// Album art cache keyed by artwork URL
    private var artworkCache: [String: NSImage] = [:]
    private var lastArtworkURL: String?

    private var pollTask: Task<Void, Never>?
    private let pollInterval: TimeInterval = 2.0

    private init() {}

    // MARK: - Lifecycle

    func start() {
        logger.info("NowPlayingService started (Spotify)")
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? 2.0))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Polling

    /// Single AppleScript that returns all fields separated by |||
    private static let pollScript = """
    if application "Spotify" is running then
        tell application "Spotify"
            if player state is not stopped then
                set t to name of current track
                set a to artist of current track
                set al to album of current track
                set art to artwork url of current track
                set s to player state as string
                set d to duration of current track
                set p to player position
                return t & "|||" & a & "|||" & al & "|||" & art & "|||" & s & "|||" & d & "|||" & p
            end if
        end tell
    end if
    """

    private func poll() async {
        let result = await executor.runWithResult(
            "/usr/bin/osascript",
            arguments: ["-e", Self.pollScript],
            timeoutSeconds: 3
        )

        switch result {
        case .success(let process):
            let output = process.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else {
                stateSubject.send(.empty)
                return
            }

            let parts = output.components(separatedBy: "|||")
            guard parts.count >= 7 else {
                stateSubject.send(.empty)
                return
            }

            let title = parts[0]
            let artist = parts[1]
            let album = parts[2]
            let artworkURL = parts[3]
            let playerState = parts[4]  // "playing", "paused"
            let durationMs = Double(parts[5]) ?? 0
            let position = Double(parts[6]) ?? 0

            // Fetch artwork when URL changes
            if artworkURL != lastArtworkURL, !artworkURL.isEmpty {
                lastArtworkURL = artworkURL
                if artworkCache[artworkURL] == nil {
                    let artwork = await fetchArtwork(url: artworkURL)
                    if let artwork { artworkCache[artworkURL] = artwork }
                }
            }

            let state = NowPlayingState(
                title: title,
                artist: artist,
                album: album,
                artwork: artworkCache[artworkURL],
                isPlaying: playerState == "playing",
                duration: durationMs / 1000.0,
                elapsed: position
            )
            stateSubject.send(state)

        case .failure:
            stateSubject.send(.empty)
        }
    }

    // MARK: - Artwork

    private func fetchArtwork(url: String) async -> NSImage? {
        guard let imageURL = URL(string: url) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: imageURL)
            return NSImage(data: data)
        } catch {
            return nil
        }
    }

    // MARK: - Controls

    func togglePlayPause() async {
        _ = await executor.runWithResult(
            "/usr/bin/osascript",
            arguments: ["-e", "tell application \"Spotify\" to playpause"],
            timeoutSeconds: 2
        )
    }

    func next() async {
        _ = await executor.runWithResult(
            "/usr/bin/osascript",
            arguments: ["-e", "tell application \"Spotify\" to next track"],
            timeoutSeconds: 2
        )
        await poll()
    }

    func previous() async {
        _ = await executor.runWithResult(
            "/usr/bin/osascript",
            arguments: ["-e", "tell application \"Spotify\" to previous track"],
            timeoutSeconds: 2
        )
        await poll()
    }
}

#endif
