#if !APP_STORE

import SwiftUI

struct NowPlayingWidget: View {
    @ObservedObject var monitor: NowPlayingMonitor
    /// When true, hide controls (Claude needs space)
    let compact: Bool
    let height: CGFloat

    var body: some View {
        if monitor.state.hasMedia {
            HStack(spacing: 4) {
                albumArt
                trackTitle

                if !compact {
                    transportControls
                }
            }
            .frame(height: height)
            .animation(.smooth(duration: 0.2), value: compact)
        }
    }

    // MARK: - Album Art

    @ViewBuilder
    private var albumArt: some View {
        if let artwork = monitor.state.artwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .frame(width: 20, height: 20)
        }
    }

    // MARK: - Track Title

    private var trackTitle: some View {
        MarqueeText(
            text: monitor.state.title ?? "",
            fontSize: 10,
            fontWeight: .medium,
            nsFontWeight: .medium,
            color: .white.opacity(0.5),
            trigger: monitor.state.title ?? ""
        )
        .frame(width: compact ? 50 : 70, height: height, alignment: .leading)
    }

    // MARK: - Transport Controls

    private var transportControls: some View {
        HStack(spacing: 2) {
            MediaControlButton(icon: "backward.fill", size: 7) {
                monitor.previous()
            }
            MediaControlButton(
                icon: monitor.state.isPlaying ? "pause.fill" : "play.fill",
                size: 8
            ) {
                monitor.togglePlayPause()
            }
            MediaControlButton(icon: "forward.fill", size: 7) {
                monitor.next()
            }
        }
    }
}

// MARK: - Control Button

private struct MediaControlButton: View {
    let icon: String
    let size: CGFloat
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundColor(isHovered ? .white.opacity(0.7) : .white.opacity(0.35))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Mini Controls (for expanded notch header)

struct NowPlayingMiniControls: View {
    @ObservedObject var monitor: NowPlayingMonitor

    var body: some View {
        HStack(spacing: 6) {
            MediaControlButton(icon: "backward.fill", size: 8) {
                monitor.previous()
            }
            MediaControlButton(
                icon: monitor.state.isPlaying ? "pause.fill" : "play.fill",
                size: 9
            ) {
                monitor.togglePlayPause()
            }
            MediaControlButton(icon: "forward.fill", size: 8) {
                monitor.next()
            }
        }
    }
}

#endif
