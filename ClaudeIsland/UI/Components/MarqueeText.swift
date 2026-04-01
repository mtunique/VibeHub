import AppKit
import SwiftUI

/// Single-run marquee: scroll long text once, then settle back at the start.
struct MarqueeText: View {
    let text: String
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let nsFontWeight: NSFont.Weight
    let color: Color
    let trigger: String

    @State private var offsetX: CGFloat = 0
    @State private var lastCompletedTrigger: String? = nil
    @State private var animationToken = UUID()
    @State private var isAnimating: Bool = false

    var body: some View {
        GeometryReader { geo in
            let available = max(0, geo.size.width)
            let textWidth = measureWidth(text: text)
            let overflow = max(0, textWidth - available)

            ZStack(alignment: .leading) {
                // Default state: keep the start visible and truncate the end with "...".
                if !isAnimating {
                    Text(text)
                        .font(.system(size: fontSize, weight: fontWeight))
                        .foregroundColor(color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: geo.size.height, alignment: .center)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Animation state: slide full text once.
                if isAnimating {
                    Text(text)
                        .font(.system(size: fontSize, weight: fontWeight))
                        .foregroundColor(color)
                        .lineLimit(1)
                        .offset(x: offsetX)
                        .frame(height: geo.size.height, alignment: .center)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onAppear {
                startIfNeeded(overflow: overflow)
            }
            .onChange(of: trigger) { _ in
                // New state => allow scrolling again.
                lastCompletedTrigger = nil
                offsetX = 0
                isAnimating = false
                startIfNeeded(overflow: overflow)
            }
        }
        .clipped()
    }

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
        let speed: CGFloat = 28 // points/sec
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
