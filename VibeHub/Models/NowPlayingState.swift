#if !APP_STORE

import AppKit

struct NowPlayingState {
    let title: String?
    let artist: String?
    let album: String?
    let artwork: NSImage?
    let isPlaying: Bool
    let duration: TimeInterval
    let elapsed: TimeInterval

    var hasMedia: Bool { title != nil }

    static let empty = NowPlayingState(
        title: nil, artist: nil, album: nil,
        artwork: nil, isPlaying: false,
        duration: 0, elapsed: 0
    )
}

extension NowPlayingState: Equatable {
    static func == (lhs: NowPlayingState, rhs: NowPlayingState) -> Bool {
        lhs.title == rhs.title &&
        lhs.artist == rhs.artist &&
        lhs.isPlaying == rhs.isPlaying &&
        lhs.duration == rhs.duration
    }
}

#endif
