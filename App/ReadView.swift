import AVFoundation
import JotCore
import SwiftUI

/// One transcript: title, Send to Claude, and the text with tappable timestamps.
struct ReadView: View {
    private var opened: Read
    /// The search that opened this transcript: matches are marked and the first one is scrolled to.
    var find: String = ""
    init(read: Read, find: String = "") { opened = read; self.find = find }
    /// Live from the library, so Listen again's new lines land while you're reading.
    private var read: Read { store.reads.first { $0.id == opened.id } ?? opened }
    /// Words Listen again changed, lit for a moment when they land.
    @State private var landed: [Int: [Range<String.Index>]] = [:]
    // Pull to refresh while Listen again runs: the same quotes as the list.
    @State private var offset: CGFloat = 0
    @State private var refreshStart: Date?
    @State private var found = "Still listening"
    @State private var snaps = 0
    private var pull: CGFloat { max(0, -offset) }
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var player = Player()
    @State private var showSend = false
    @State private var copied = false
    @State private var hit = 0
    @AppStorage("includeTimestamps") private var timestamps = true
    @AppStorage("sendAsFile") private var asFile = false

    /// Lines that contain the search, in order.
    private var hits: [Int] {
        guard !Find.trimmed(find).isEmpty else { return [] }
        return read.segments.indices.filter { Find.matches(read.segments[$0].text, find) }
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Room for the quotes to finish after you let go.
                Color.clear.frame(height: refreshStart == nil ? 0 : 62)
                Text(read.displayTitle)
                    .font(.onest(27, .bold))
                    .foregroundStyle(Color.jInk)
                    .fixedSize(horizontal: false, vertical: true)
                meta.padding(.top, 8)
                original.padding(.top, 6)
                actions.padding(.leading, Inset.edge - Inset.text).padding(.top, 16).padding(.bottom, 10)
                #if os(iOS)
                // Up here with the other actions, where it's seen before you start reading.
                again.padding(.top, 6).padding(.bottom, 12)
                #endif
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(read.segments.enumerated()), id: \.offset) { i, seg in
                        SegmentRow(segment: seg, isNow: player.isNear(seg), find: find, landed: landed[i] ?? []) {
                            player.play(from: seg.start)
                        }
                        .id(i)
                    }
                }
                .padding(.top, 4)
                #if os(iOS)
                .modifier(Relistening(active: relistening))
                #endif
                Color.clear.frame(height: 90)
            }
            .padding(.horizontal, Inset.text)
            #if os(iOS)
            .frame(maxWidth: Inset.reading, alignment: .leading)
            .frame(maxWidth: .infinity)
            #endif
        }
        .background(Color.jBg)
        #if os(iOS)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, v in offset = v }
        .onScrollPhaseChange { old, new in
            if old == .interacting, new != .interacting, pull >= PullQuotes.threshold, refreshStart == nil, relistening { startRefresh() }
        }
        .overlay(alignment: .top) {
            if relistening || refreshStart != nil, pull > 1 || refreshStart != nil {
                PullQuotes(pull: pull, refreshStart: refreshStart, words: found)
                    .frame(height: max(pull, refreshStart == nil ? 0 : 62 + pull))
                    .offset(y: -max(0, offset))
                    .clipped()
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: pull >= PullQuotes.threshold) { _, armed in armed && refreshStart == nil && relistening }
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.9), trigger: snaps)
        .sensoryFeedback(trigger: PullQuotes.stretchStep(for: pull)) { old, new in
            new > old && refreshStart == nil && relistening ? .impact(flexibility: .rigid, intensity: PullQuotes.stretchIntensity(new)) : nil
        }
        .sensoryFeedback(trigger: refreshStart) { old, new in
            old == nil && new != nil ? .impact(weight: .heavy, intensity: 0.7 + 0.3 * Double(PullQuotes.stretch(for: pull))) : nil
        }
        #endif
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if hits.count > 1 { stepper(proxy) }
                if player.isReady { PlayerBar(player: player).padding(.horizontal, Inset.edge) }
            }
            .padding(.bottom, 8)
            #if os(iOS)
            .frame(maxWidth: Inset.reading + 2 * (Inset.edge - Inset.text))
            .frame(maxWidth: .infinity)
            #endif
        }
        .task {
            // Open at the first match, a beat after the push so the scroll lands.
            guard let first = hits.first else { return }
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(.snappy(duration: 0.4)) { proxy.scrollTo(first, anchor: .center) }
        }
        }
        .onChange(of: read.segments) { old, new in
            // Listen again landed: light up what it heard differently, then let it settle.
            guard !old.isEmpty, old.map(\.text) != new.map(\.text) else { return }
            landed = Fixed.changed(from: old.map(\.text), to: new.map(\.text))
            Task {
                try? await Task.sleep(for: .seconds(2.2))
                withAnimation(.easeOut(duration: 0.8)) { landed = [:] }
            }
        }
        #if os(iOS)
        .animation(.easeInOut(duration: 0.6), value: relistening)
        #endif
        .sheet(isPresented: $showSend) { SendSheet(read: read) }
        .onAppear { player.load(store.audioURL(for: read), duration: read.duration) }
        .onDisappear { player.stop() }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Delete", systemImage: "trash", role: .destructive) { store.delete(read); dismiss() }
                } label: { Image(systemName: "ellipsis") }
            }
        }
    }

    #if os(iOS)
    /// Links that haven't had the careful pass yet, with cloud fetch set up and nothing already running.
    private var canListenAgain: Bool {
        read.kind == .link && store.cloudReady && !read.model.contains(CloudFetcher.carefulModel)
            && !store.listeningAgain.contains(read.id)
    }

    private var relistening: Bool { store.listeningAgain.contains(read.id) }

    /// Checks the cloud now. The quotes say whether the careful listen is still going or has landed.
    private func startRefresh() {
        withAnimation(.snappy(duration: 0.3)) { refreshStart = .now }
        found = "Still listening"
        store.refresh()
        Task {
            // Collecting the run takes a few seconds; give it most of the animation before saying.
            try? await Task.sleep(for: .seconds(0.9))
            found = relistening ? "Still listening" : "Listened again"
            try? await Task.sleep(for: .seconds(PullQuotes.snapAt - 0.9))
            snaps += 1
            try? await Task.sleep(for: .seconds(PullQuotes.duration - PullQuotes.snapAt))
            withAnimation(.snappy(duration: 0.35)) { refreshStart = nil }
        }
    }

    /// Under the actions: an offer to listen again, the orb while it does, or why it couldn't.
    @ViewBuilder private var again: some View {
        if relistening {
            HStack(spacing: 12) {
                OrbView(kind: .listening, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Listening again…").font(.onest(15, .semibold)).foregroundStyle(Color.jInk)
                    Text("A slower, sharper listen. You can leave; Jot will tell you.")
                        .font(.onest(13)).foregroundStyle(Color.jMute)
                }
            }
            .transition(.opacity)
        } else if let error = store.listenAgainError[read.id] {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Couldn't listen again: \(error)").font(.onest(13.5)).foregroundStyle(Color.jMute)
                Button("OK") { store.dismissListenAgainError(read.id) }
                    .font(.onest(13.5, .semibold)).foregroundStyle(Color.jCyanText).buttonStyle(.plain)
            }
        } else if canListenAgain {
            Button { store.listenAgain(read) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "ear").font(.system(size: 16, weight: .semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Didn't catch it all? Listen again").font(.onest(15, .semibold))
                        Text("Slower and sharper, for fast or mumbled speech")
                            .font(.onest(13)).foregroundStyle(Color.jMute)
                    }
                }
                .foregroundStyle(Color.jCyanText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .transition(.opacity)
        } else if read.model.contains(CloudFetcher.carefulModel) {
            Label("Listened to again", systemImage: "ear")
                .font(.onest(13, .medium))
                .foregroundStyle(Color.jMute)
        }
    }
    #endif

    /// "2 of 5" with up and down, to walk through every line that matches.
    private func stepper(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 4) {
            Text("“\(Find.trimmed(find))”").lineLimit(1).foregroundStyle(Color.jInk)
            Text("\(hit + 1) of \(hits.count)").foregroundStyle(Color.jMute).monospacedDigit()
                .padding(.leading, 4)
            Button { go(-1, proxy) } label: { Image(systemName: "chevron.up").frame(width: 30, height: 30) }
                .accessibilityLabel("Previous match")
            Button { go(1, proxy) } label: { Image(systemName: "chevron.down").frame(width: 30, height: 30) }
                .accessibilityLabel("Next match")
        }
        .font(.onest(14, .semibold))
        .buttonStyle(.plain)
        .foregroundStyle(Color.jCyanText)
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 44)
        .glassEffect(.regular.interactive(), in: .capsule)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, Inset.edge)
    }

    private func go(_ step: Int, _ proxy: ScrollViewProxy) {
        hit = (hit + step + hits.count) % hits.count
        withAnimation(.snappy(duration: 0.35)) { proxy.scrollTo(hits[hit], anchor: .center) }
    }

    private var meta: some View {
        HStack(spacing: 4) {
            let source = [read.handle ?? read.creator, read.site].compactMap { $0 }.joined(separator: " · ")
            Text(source.isEmpty ? "Voice memo" : source)
            if let d = read.duration {
                Text("·")
                Text(Read.clock(d)).font(.mono(11))
            }
            Text("·")
            Text(read.posted ?? read.created, format: .dateTime.day().month(.abbreviated))
        }
        .font(.onest(13.5))
        .foregroundStyle(Color.jMute)
        .lineLimit(1)
    }

    /// Back to the post it came from, opening in that app (Instagram, TikTok…) when it's installed.
    @ViewBuilder private var original: some View {
        if read.kind == .link, let url = URL(string: read.source), url.scheme?.hasPrefix("http") == true {
            Link(destination: url) {
                HStack(spacing: 4) {
                    Text("View on \(read.site ?? url.host()?.replacingOccurrences(of: "www.", with: "") ?? "the web")")
                    Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .bold))
                }
                .font(.onest(13.5, .semibold))
                .foregroundStyle(Color.jCyanText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            #if os(iOS)
            // One tap to the share sheet, where Claude lets you pick the chat. Options live behind the share icon.
            Group {
                if asFile {
                    ShareLink(item: read.markdownFile(timestamps: timestamps)) { sendLabel }
                } else {
                    ShareLink(item: read.markdown(timestamps: timestamps)) { sendLabel }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            #else
            Button { showSend = true } label: { sendLabel }
                .buttonStyle(PrimaryButtonStyle())
            #endif
            Button {
                Clipboard.copy(read.markdown())
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(SecondaryButtonStyle())
            #if os(iOS)
            Button { showSend = true } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel("More ways to send")
            #else
            ShareLink(item: read.markdown()) { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(SecondaryButtonStyle())
            #endif
        }
    }

    private var sendLabel: some View {
        HStack(spacing: 6) {
            Image("QuoteMark").resizable().scaledToFit().frame(height: 15)
            Text("Send to Claude")
        }
    }
}

struct SegmentRow: View {
    var segment: Read.Segment
    var isNow: Bool
    var find: String = ""
    /// Words Listen again just changed, lit cyan for a moment.
    var landed: [Range<String.Index>] = []
    var onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Read.clock(segment.start))
                    .font(.mono(11))
                    .foregroundStyle(Color.jCyanText)
                    .frame(width: 44, alignment: .leading)
                Text(marked)
                    .font(.onest(16.5))
                    .lineSpacing(4)
                    .foregroundStyle(Color.jInk)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, isNow ? 3 : 0)
                    .background(isNow ? Color.jCyan.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textSelection(.enabled)
        .contextMenu {
            if let heard = segment.heard {
                // What Whisper actually wrote, before Claude fixed a misheard word.
                Section("Whisper heard") { Text(heard) }
            }
            Button("Copy line", systemImage: "doc.on.doc") { Clipboard.copy(segment.text) }
        }
        .accessibilityHint(segment.heard.map { "Corrected. Whisper heard: \($0)" } ?? "")
    }

    private var marked: AttributedString {
        var out = Find.marked(segment.text, find)
        Fixed.mark(&out, text: segment.text, heard: segment.heard)
        for r in landed where r.upperBound <= segment.text.endIndex {
            if let lower = AttributedString.Index(r.lowerBound, within: out), let upper = AttributedString.Index(r.upperBound, within: out) {
                out[lower..<upper].backgroundColor = Color.jCyan.opacity(0.35)
            }
        }
        return out
    }
}

/// Plays the source audio; tapping a line seeks to it.
@MainActor @Observable
final class Player {
    private var avPlayer: AVPlayer?
    private var observer: Any?
    private(set) var time: Double = 0
    private(set) var duration: Double = 1
    private(set) var isPlaying = false
    var isReady: Bool { avPlayer != nil }

    func load(_ url: URL?, duration: Double?) {
        guard avPlayer == nil, let url, FileManager.default.fileExists(atPath: url.path) else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        #endif
        let p = AVPlayer(url: url)
        self.duration = max(1, duration ?? 1)
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                self?.time = t.seconds
                self?.isPlaying = (self?.avPlayer?.rate ?? 0) > 0
            }
        }
        avPlayer = p
    }

    func play(from seconds: Double) {
        avPlayer?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        avPlayer?.play()
        isPlaying = true
    }

    func toggle() {
        guard let avPlayer else { return }
        if avPlayer.rate > 0 { avPlayer.pause(); isPlaying = false } else { avPlayer.play(); isPlaying = true }
    }

    func stop() { avPlayer?.pause() }

    func isNear(_ seg: Read.Segment) -> Bool {
        (isPlaying || time > 0) && time >= seg.start && time < seg.end
    }
}

struct PlayerBar: View {
    var player: Player
    var body: some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.jBg)
                    .frame(width: 38, height: 38)
                    .background(Color.jInk, in: Circle())
            }
            .buttonStyle(.plain)
            Waveform(progress: player.time / player.duration)
            Text(Read.clock(player.time)).font(.mono(11)).foregroundStyle(Color.jMute)
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .background(Color.jSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.jLine))
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
    }
}

/// Decorative bars that fill cyan as it plays.
struct Waveform: View {
    var progress: Double
    var body: some View {
        GeometryReader { geo in
            let n = 46
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<n, id: \.self) { i in
                    let h = 0.2 + 0.7 * abs(sin(Double(i) * 1.7) * cos(Double(i) * 0.45))
                    Capsule()
                        .fill(Double(i) / Double(n) < progress ? Color.jCyan : Color.jSurface2)
                        .frame(height: geo.size.height * h)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 30)
    }
}

#if os(iOS)
/// While Listen again works, the transcript dims and a soft band of light passes down it, like the
/// words are being heard a second time. With Reduce Motion it just dims.
private struct Relistening: ViewModifier {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active {
            content
                .mask {
                    GeometryReader { geo in
                        TimelineView(.animation(paused: reduceMotion)) { ctx in
                            let band: CGFloat = 220
                            let period = 2.8
                            let p = reduceMotion ? -1 : ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                            ZStack(alignment: .top) {
                                Color.black.opacity(0.28)
                                LinearGradient(colors: [.clear, .black, .clear], startPoint: .top, endPoint: .bottom)
                                    .frame(height: band)
                                    .offset(y: CGFloat(p) * (geo.size.height + band) - band)
                            }
                        }
                    }
                }
                .allowsHitTesting(false)
        } else {
            content
        }
    }
}
#endif
