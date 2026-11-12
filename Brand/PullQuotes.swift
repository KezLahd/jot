import SwiftUI

/// The Jot "long comma" j, from the locked mark (`design/mockups/jot-mark.js`): head r 12.5 at the origin,
/// tail curving down-left to a round end, tilted 10° anticlockwise. `count` 2 gives the closing quote ”.
struct JotGlyph: Shape {
    var count = 1

    static let unit: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 12.5, y: 0))
        p.addCurve(to: CGPoint(x: -14.66, y: 75.5), control1: CGPoint(x: 12.5, y: 32), control2: CGPoint(x: 5, y: 62))
        // Round end of the tail: a half circle r 6.
        p.addArc(center: CGPoint(x: -17, y: 70), radius: 6, startAngle: .degrees(66.95), endAngle: .degrees(246.95), clockwise: false)
        p.addCurve(to: CGPoint(x: -4.28, y: 11.75), control1: CGPoint(x: -8, y: 58), control2: CGPoint(x: -3, y: 28))
        // The head: most of a circle r 12.5 back to the start.
        p.addArc(center: .zero, radius: 12.5, startAngle: .degrees(110), endAngle: .degrees(360), clockwise: false)
        p.closeSubpath()
        return p.applying(CGAffineTransform(rotationAngle: -10 * .pi / 180))
    }()

    func path(in rect: CGRect) -> Path {
        var p = Path()
        for i in 0..<count { p.addPath(Self.unit, transform: CGAffineTransform(translationX: CGFloat(i) * 31, y: 0)) }
        let b = p.boundingRect
        let s = min(rect.width / b.width, rect.height / b.height)
        let t = CGAffineTransform(translationX: -b.minX, y: -b.minY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: rect.midX - b.width * s / 2, y: rect.midY - b.height * s / 2))
        return p.applying(t)
    }
}

/// Pull to refresh, Jot style. Pulling splits the j into an opening “ and a closing ” that spread apart.
/// Let go and they draw in, a waveform plays between them and turns into words saying what the pull found,
/// then the “ snaps shut against the ” and the pair tucks away.
struct PullQuotes: View {
    var pull: CGFloat
    var refreshStart: Date?
    /// What the pull found, e.g. "All caught up" or "2 new". Shown between the quotes.
    var words: String = "All caught up"
    static let threshold: CGFloat = 86
    static let duration: TimeInterval = 2.6
    /// When the quotes meet, for the haptic.
    static let snapAt: TimeInterval = 2.12
    @State private var measured: CGFloat = 0

    /// How hard the pull is stretching past the line, 0 to nearly 1: the quotes draw out taller and lean apart.
    static func stretch(for pull: CGFloat) -> CGFloat {
        pull > threshold ? 1 - exp(-(pull - threshold) / 110) : 0
    }

    /// A tick for each step of overpull. The steps close up the further you go, so the haptics speed up like
    /// a rubber band getting tighter (the scroll view's own resistance would otherwise slow them down).
    static func stretchStep(for pull: CGFloat) -> Int {
        guard pull > threshold + 20 else { return 0 }
        return min(120, 1 + Int(pow((pull - threshold - 20) / 30, 1.7)))
    }

    /// Ticks firm up as the band tightens.
    static func stretchIntensity(_ step: Int) -> Double { 0.3 + 0.7 * min(1, Double(step) / 22) }
    private var wordsWidth: CGFloat { measured > 0 ? measured : CGFloat(words.count) * 8.2 }

    var body: some View {
        TimelineView(.animation(paused: refreshStart == nil)) { context in
            let t = refreshStart.map { context.date.timeIntervalSince($0) }
            content(t: t)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static let markH: CGFloat = 22
    /// Half the gap between the two j's of a quote mark (31 units apart in the locked mark, about 95 tall).
    private static let half: CGFloat = markH * 15.5 / 95
    /// Half the width of a whole quote mark, so two can sit side by side without touching.
    private static let markHalfWidth: CGFloat = 8.5

    @ViewBuilder func content(t: TimeInterval?) -> some View {
        if let t {
            release(t)
        } else {
            pulling
        }
    }

    // MARK: Pull

    /// The j appears in the middle, then slides right to become the first j of the closing ”; its partner fades
    /// in beside it, already in place. The opening “ starts just clear of the j on the left and travels out.
    private var pulling: some View {
        let p = min(1, pull / Self.threshold)
        let appear = min(1, p / 0.3)
        let split = ease((p - 0.3) / 0.7)
        let armed = p >= 1
        let colour: Color = armed ? .jCyanText : .jMute
        let jx = (58 - Self.half) * split
        let clear = 2 * Self.markHalfWidth + 2  // nearest the “ can be to the j without touching
        // Past the line the pair is stretched like a band: drawn out taller and thinner, leaning away from each other.
        let s = Self.stretch(for: pull)
        let out = 16 * s
        return ZStack {
            opening(at: 0, colour: colour)
                .scaleEffect(x: 1 - 0.14 * s, y: 1 + 0.3 * s)
                .rotationEffect(.degrees(-9 * s))
                .offset(x: jx - clear - (58 + jx - clear) * split - out)
                .opacity(split)
                .scaleEffect(0.7 + 0.3 * split)
            ZStack {
                glyph(at: Self.half, colour: colour)
                    .opacity(split)
                glyph(at: -Self.half, colour: colour)
                    .opacity(appear)
                    .scaleEffect(0.6 + 0.4 * appear)
            }
            .scaleEffect(x: 1 - 0.14 * s, y: 1 + 0.3 * s)
            .rotationEffect(.degrees(9 * s))
            .offset(x: jx + Self.half + out)
        }
        .animation(.snappy(duration: 0.18), value: armed)
    }

    // MARK: Release

    private func release(_ t: TimeInterval) -> some View {
        let condense = ease(t / 0.3)
        let wave = ease((t - 0.15) / 0.25) * (1 - ease((t - 0.85) / 0.3))
        let reveal = ease((t - 0.95) / 0.4)
        let widen = ease((t - 0.85) / 0.35)
        // The quotes open to hold the words, then slam shut: an ease-in so they arrive fast.
        let wrap = max(44, wordsWidth / 2 + Self.markHalfWidth + 7)
        let held = (58 - 14 * condense) * (1 - widen) + wrap * widen
        let shut = slam((t - (Self.snapAt - 0.22)) / 0.22)
        let spread = held + (Self.markHalfWidth + 0.5 - held) * shut
        // Contact: a quick swell and settle, then the pair shrinks away.
        let u = (t - Self.snapAt) / 0.24
        let bounce = u > 0 && u < 1 ? 0.2 * sin(.pi * u) * (1 - u) : 0
        let away = ease((t - 2.32) / 0.26)
        // The words are squeezed by the quotes closing on them.
        let room = 2 * (spread - Self.markHalfWidth - 5)
        let squeeze = min(1, max(0, room / max(wordsWidth, 1)))
        return ZStack {
            opening(at: -spread, colour: .jCyanText)
            glyph(at: spread - Self.half, colour: .jCyanText)
            glyph(at: spread + Self.half, colour: .jCyanText)
            PullWave(t: t, flatten: 1 - wave)
                .opacity(wave)
                .scaleEffect(x: 0.6 + 0.4 * wave)
            Text(words)
                .font(.onest(15, .semibold))
                .foregroundStyle(Color.jInk)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured = $0 }
                // Written in from the left, like the waveform being turned into text.
                .mask {
                    let head = reveal * 1.2
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: max(0, head - 0.2)),
                                           .init(color: .clear, location: head)],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .opacity(reveal > 0 ? (squeeze < 0.5 ? squeeze * 2 : 1) : 0)
                .scaleEffect(x: max(0.01, squeeze))
        }
        .scaleEffect(CGFloat(1 + bounce) * (1 - 0.5 * away))
        .opacity(1 - away)
    }

    private func glyph(at x: CGFloat, colour: Color, flipped: Bool = false) -> some View {
        JotGlyph().fill(colour)
            .frame(width: Self.markH, height: Self.markH)
            .rotationEffect(.degrees(flipped ? 180 : 0))
            .offset(x: x)
    }

    /// The opening “ is the closing ” turned upside down.
    private func opening(at x: CGFloat, colour: Color) -> some View {
        ZStack {
            glyph(at: -Self.half, colour: colour, flipped: true)
            glyph(at: Self.half, colour: colour, flipped: true)
        }
        .offset(x: x)
    }

    private func ease(_ x: Double) -> CGFloat {
        let c = min(1, max(0, x))
        return CGFloat(c * c * (3 - 2 * c))
    }

    private func slam(_ x: Double) -> CGFloat {
        let c = min(1, max(0, x))
        return CGFloat(c * c * c)
    }
}

/// Bars that move like speech, flattening to a line as the words take over.
private struct PullWave: View {
    var t: TimeInterval
    var flatten: CGFloat
    private let count = 7

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<count, id: \.self) { i in
                let level = 0.25 + 0.75 * abs(sin(t * 7.5 + Double(i) * 0.9) * cos(t * 3.1 + Double(i) * 0.45))
                Capsule()
                    .fill(Color.jCyan)
                    .frame(width: 4, height: max(3, CGFloat(level) * 18 * (1 - flatten)))
            }
        }
        .frame(height: 24)
    }
}
