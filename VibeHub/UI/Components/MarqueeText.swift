import AppKit
import SwiftUI

/// Marquee text that scrolls when content overflows.
/// Set `loop` to `true` for continuous cycling, or `false` for a single scroll pass.
struct MarqueeText: View {
    let text: String
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let nsFontWeight: NSFont.Weight
    let color: Color
    let trigger: String
    var loop: Bool = false

    @State private var offsetX: CGFloat = 0
    @State private var lastCompletedTrigger: String? = nil
    @State private var animationToken = UUID()
    @State private var isAnimating: Bool = false

    private let gap: CGFloat = 40

    var body: some View {
        GeometryReader { geo in
            let available = max(0, geo.size.width)
            let textWidth = measureWidth(text: text)
            let overflow = max(0, textWidth - available)
            let needsScroll = overflow > 6

            ZStack(alignment: .leading) {
                if loop && needsScroll {
                    // Looping mode: two copies side by side
                    HStack(spacing: gap) {
                        marqueeTextItem
                        marqueeTextItem
                    }
                    .offset(x: offsetX)
                    .frame(height: geo.size.height, alignment: .center)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onAppear {
                        startLooping(textWidth: textWidth)
                    }
                    .onChange(of: trigger) { _ in
                        resetAndStartLooping(textWidth: textWidth)
                    }
                } else if !loop && isAnimating {
                    marqueeTextItem
                        .offset(x: offsetX)
                        .frame(height: geo.size.height, alignment: .center)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(text)
                        .font(.system(size: fontSize, weight: fontWeight))
                        .foregroundColor(color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: geo.size.height, alignment: .center)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onAppear {
                if !loop { startIfNeeded(overflow: overflow) }
            }
            .onChange(of: trigger) { _ in
                if !loop {
                    lastCompletedTrigger = nil
                    offsetX = 0
                    isAnimating = false
                    startIfNeeded(overflow: overflow)
                }
            }
        }
        .clipped()
    }

    private var marqueeTextItem: some View {
        Text(text)
            .font(.system(size: fontSize, weight: fontWeight))
            .foregroundColor(color)
            .lineLimit(1)
            .fixedSize()
    }

    // MARK: - Loop mode

    private func startLooping(textWidth: CGFloat) {
        let token = UUID()
        animationToken = token
        offsetX = 0

        let scrollDistance = textWidth + gap
        let speed: CGFloat = 30
        let duration = TimeInterval(scrollDistance / max(1, speed))

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard animationToken == token else { return }
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                offsetX = -scrollDistance
            }
        }
    }

    private func resetAndStartLooping(textWidth: CGFloat) {
        offsetX = 0
        animationToken = UUID()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            startLooping(textWidth: textWidth)
        }
    }

    // MARK: - Single-pass mode

    private func startIfNeeded(overflow: CGFloat) {
        guard overflow > 6 else {
            offsetX = 0
            isAnimating = false
            return
        }
        guard lastCompletedTrigger != trigger else {
            offsetX = 0
            isAnimating = false
            return
        }

        let token = UUID()
        animationToken = token

        let pause: TimeInterval = 0.35
        let speed: CGFloat = 28
        let duration = TimeInterval(overflow / max(1, speed))

        offsetX = 0
        isAnimating = true
        withAnimation(.linear(duration: duration).delay(pause)) {
            offsetX = -overflow
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pause + duration + 0.15) {
            guard animationToken == token else { return }
            offsetX = 0
            isAnimating = false
            lastCompletedTrigger = trigger
        }
    }

    private func measureWidth(text: String) -> CGFloat {
        let nsFont = NSFont.systemFont(ofSize: fontSize, weight: nsFontWeight)
        let attrs: [NSAttributedString.Key: Any] = [.font: nsFont]
        return (text as NSString).size(withAttributes: attrs).width
    }
}
