import JotCore
import SwiftUI

/// The whole app in one list: open it, see your transcripts.
///
/// The masthead folds the way Fabrica's does: it follows the finger, worked out from the scroll offset with no
/// threshold. The wordmark shrinks in place and the search and filter rows slide up under the bar. Let go
/// part-way and it settles open or folded, whichever is nearer. Pulling down leaves it where it is; the quotes
/// play in the gap that opens under it.
struct LibraryView: View {
    @Environment(Store.self) private var store
    @State private var query = ""
    @State private var filter: Store.Filter = .all
    @State private var sort: Store.Sort = .newest
    @State private var limit = LibraryView.page
    @State private var path = NavigationPath()
    @State private var showDeleted = false
    @State private var showCloud = false
    @State private var showSettings = false
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @State private var recording = false
    @State private var adding = false
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var confirmDelete = false
    @State private var swiped: String?
    @State private var offset: CGFloat = 0
    @State private var toolsHeight: CGFloat = 92
    @State private var insetTop: CGFloat = 0
    @State private var scroll = ScrollPosition()
    @State private var refreshStart: Date?
    @State private var found = "All caught up"
    @State private var snaps = 0
    @FocusState private var searching: Bool

    static let page = 60
    private let barHeight: CGFloat = 52

    /// How far the masthead has folded, 0 open to 1 folded.
    private var travel: CGFloat { min(max(0, offset), toolsHeight) }
    private var progress: CGFloat { toolsHeight > 0 ? travel / toolsHeight : 0 }
    private var pull: CGFloat { max(0, -offset) }
    private var mastheadHeight: CGFloat { barHeight + toolsHeight }

    #if os(iOS)
    private func startRefresh() {
        refreshStart = .now
        found = "All caught up"
        let before = Set(store.reads.map(\.id))
        store.refresh()
        Task {
            // Give iCloud a moment, then say what turned up before the words are written in.
            try? await Task.sleep(for: .seconds(0.7))
            let new = store.reads.filter { !before.contains($0.id) }.count
            let running = store.requests.filter { $0.state != .failed }.count
            found = new == 1 ? "1 new transcript" : new > 1 ? "\(new) new transcripts"
                : running == 1 ? "1 on the way" : running > 1 ? "\(running) on the way" : "All caught up"
            try? await Task.sleep(for: .seconds(PullQuotes.snapAt - 0.7))
            snaps += 1
            try? await Task.sleep(for: .seconds(PullQuotes.duration - PullQuotes.snapAt))
            refreshStart = nil
        }
    }
    #endif

    private func openPending() {
        guard let id = store.openReadID, let read = store.reads.first(where: { $0.id == id }) else { return }
        store.openReadID = nil
        path = NavigationPath([read])
    }

    var body: some View {
        let all = store.items(matching: query, filter: filter, sort: sort)
        let shown = all.prefix(limit)
        NavigationStack(path: $path) {
            list(all: all, shown: Array(shown))
                .overlay(alignment: .top) { masthead }
                .overlay { if all.isEmpty { empty.padding(.top, mastheadHeight) } }
                .safeAreaInset(edge: .bottom) { if !searching { dock } }
                .background(Color.jBg)
                .navigationDestination(for: Read.self) { ReadView(read: $0) }
                .navigationDestination(for: FoundRead.self) { ReadView(read: $0.read, find: $0.query) }
                .navigationDestination(for: Request.self) { RequestView(requestID: $0.id) }
                // A tapped "Transcript ready" notification. The Read may still be on its way from iCloud.
                .onChange(of: store.openReadID) { openPending() }
                .onChange(of: store.reads) { openPending() }
                .onChange(of: query) { limit = Self.page }
                .onChange(of: filter) { limit = Self.page }
                .onChange(of: sort) { limit = Self.page }
                .sheet(isPresented: $showDeleted) { DeletedView() }
                #if os(iOS)
                .sheet(isPresented: $showCloud) { CloudSettingsView() }
                .sheet(isPresented: $showSettings) { SettingsView() }
                .fullScreenCover(isPresented: $recording) { RecordView() }
                .toolbar(.hidden, for: .navigationBar)
                #endif
                .confirmationDialog("Delete \(selected.count == 1 ? "1 transcript" : "\(selected.count) transcripts")?",
                                    isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        store.delete(all.filter { selected.contains($0.id) })
                        selected = []
                        selecting = false
                    }
                } message: { Text("They go to Recently deleted for 30 days.") }
        }
        .tint(Color.jCyanText)
        .sheet(isPresented: $adding) {
            LinkSheet()
                .presentationDetents([.height(268)])
                .presentationDragIndicator(.visible)
        }
        .alert("Jot", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK") { store.message = nil }
        } message: { Text(store.message ?? "") }
    }

    // MARK: List

    private func list(all: [Store.Item], shown: [Store.Item]) -> some View {
        // A lazy ScrollView, not a List: List ignores scroll targets, so the fold couldn't settle.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if sort.byDay {
                    ForEach(Store.byDay(shown), id: \.day) { section in
                        dayLabel(section.day)
                        ForEach(section.items) { item in line(item, last: item.id == shown.last?.id, total: all.count) }
                    }
                } else {
                    ForEach(shown) { item in line(item, last: item.id == shown.last?.id, total: all.count) }
                }
                footer(shown: shown.count, total: all.count)
            }
        }
        .contentMargins(.top, mastheadHeight + (refreshStart == nil ? 0 : 62), for: .scrollContent)
        .contentMargins(.top, mastheadHeight, for: .scrollIndicators)
        .animation(.snappy(duration: 0.35), value: refreshStart == nil)
        .scrollPosition($scroll)
        .scrollTargetBehavior(FoldSnap(range: toolsHeight, insetTop: insetTop))
        .scrollEdgeEffectHidden(true, for: .top)
        .scrollDismissesKeyboard(.immediately)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, v in
            offset = v
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.top } action: { _, v in insetTop = v }
        .onScrollPhaseChange { old, new in
            #if os(iOS)
            if old == .interacting, new != .interacting, pull >= PullQuotes.threshold, refreshStart == nil { startRefresh() }
            #endif
            if new == .interacting, swiped != nil { withAnimation(.snappy(duration: 0.25)) { swiped = nil } }
            // A slow let-go has no fling to redirect, so settle it here.
            if new == .idle, travel > 0.5, travel < toolsHeight - 0.5 {
                withAnimation(.snappy(duration: 0.3)) { scroll.scrollTo(y: (travel < toolsHeight / 2 ? 0 : toolsHeight) - insetTop) }
            }
        }
        #if os(iOS)
        .overlay(alignment: .top) {
            if pull > 1 || refreshStart != nil {
                PullQuotes(pull: pull, refreshStart: refreshStart, words: found)
                    .frame(height: max(pull, refreshStart == nil ? 0 : 62 + pull))
                    // It lives in the gap above the first row, so it scrolls up with the list and slides under the header.
                    .offset(y: -max(0, offset))
                    .opacity(1 - min(1, max(0, offset) / 50))
                    .clipped()
                    .padding(.top, mastheadHeight)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: pull >= PullQuotes.threshold) { _, armed in armed && refreshStart == nil }
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.9), trigger: snaps)
        // Past the line, ticks that come faster and firmer the further you stretch it.
        .sensoryFeedback(trigger: PullQuotes.stretchStep(for: pull)) { old, new in
            new > old && refreshStart == nil ? .impact(flexibility: .rigid, intensity: PullQuotes.stretchIntensity(new)) : nil
        }
        // Letting go: a thud like a band snapping back, harder the further it was stretched.
        .sensoryFeedback(trigger: refreshStart) { old, new in
            old == nil && new != nil ? .impact(weight: .heavy, intensity: 0.7 + 0.3 * Double(PullQuotes.stretch(for: pull))) : nil
        }
        #endif
    }

    private func dayLabel(_ day: String) -> some View {
        Text(day.uppercased())
            .font(.mono(10.5))
            .tracking(0.8)
            .foregroundStyle(Color.jMute)
            .padding(EdgeInsets(top: 22, leading: Inset.text, bottom: 6, trailing: Inset.text))
    }

    /// One transcript or job, on a hairline. The last one on the page loads the next page.
    private func line(_ item: Store.Item, last: Bool, total: Int) -> some View {
        row(item)
            .padding(.vertical, 13)
            .padding(.horizontal, Inset.text)
            .background(Color.jBg)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.jLine).frame(height: 0.5).padding(.horizontal, Inset.text) }
            .modifier(SwipeToDelete(id: item.id, open: $swiped, enabled: !selecting, title: {
                if case .request = item { "Remove" } else { "Delete" }
            }()) {
                switch item {
                case .read(let read): store.delete(read)
                case .request(let request): store.remove(request)
                }
            })
            .onAppear { if last, limit < total { limit += Self.page } }
    }

    private func footer(shown: Int, total: Int) -> some View {
        Text(total == 0 ? "" : shown < total ? "\(shown) of \(total)" : total == 1 ? "1 transcript" : "\(total) transcripts")
            .font(.onest(13, .medium))
            .foregroundStyle(Color.jMute)
            .frame(maxWidth: .infinity)
            .padding(.top, 18)
            .padding(.bottom, 24)
    }

    // MARK: Masthead

    private var masthead: some View {
        VStack(spacing: 0) {
            // The bar sits over the tools so they slide under it, not across the wordmark.
            bar.frame(height: barHeight).background(Color.jBg).zIndex(1)
            tools
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { toolsHeight = $0 }
                .offset(y: -travel)
                .opacity(1 - min(1, progress * 1.6))
        }
        .frame(height: mastheadHeight - travel, alignment: .top)
        .clipped()
        .background(Color.jBg.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.jLine).frame(height: 0.5).opacity(progress) }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Image("Wordmark").resizable().scaledToFit()
                .frame(height: 32 - 8 * progress)
                .accessibilityLabel("Jot")
            Spacer()
            if selecting {
                Button(selected.count == store.items(matching: query, filter: filter, sort: sort).count ? "None" : "All") {
                    let ids = store.items(matching: query, filter: filter, sort: sort).map(\.id)
                    selected = selected.count == ids.count ? [] : Set(ids)
                }
                .clearGlass()
                Button("Done") { withAnimation(.snappy(duration: 0.25)) { selecting = false; selected = [] } }
                    .buttonStyle(.glassProminent)
                    .tint(Color.jCyan)
                    .foregroundStyle(Color.jOnCyan)
            } else {
                Button("Select") { withAnimation(.snappy(duration: 0.25)) { selecting = true } }
                    .clearGlass()
                    .disabled(store.reads.isEmpty && store.requests.isEmpty)
                menu
            }
        }
        .font(.onest(15, .semibold))
        .padding(.leading, Inset.text)
        .padding(.trailing, Inset.edge)
    }

    @ViewBuilder private var menu: some View {
        #if os(iOS)
        Button { showSettings = true } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.jInk)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Settings")
        #else
        // Settings on the Mac is its own window (⌘,), with Recently deleted and the library in it.
        // A plain Button styled like Select: SettingsLink took the accent colour as a prominent button.
        Button { openSettings() } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.jInk)
                .frame(width: 22, height: 22)
        }
        .clearGlass(circle: true)
        .help("Settings")
        #endif
    }

    /// Search, then the filters as plain words and the sort, all inline. No boxes.
    private var tools: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.jMute)
                TextField("Search transcripts", text: $query)
                    .font(.onest(16))
                    .textFieldStyle(.plain)
                    .foregroundStyle(Color.jInk)
                    .focused($searching)
                    .submitLabel(.search)
                    .onSubmit { searching = false }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.jMute) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                }
                if searching {
                    Button("Done") { searching = false }
                        .font(.onest(15, .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.jCyanText)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Color.jSurface2, in: Capsule())
            .padding(.horizontal, Inset.edge)

            HStack(spacing: 18) {
                ForEach(Store.Filter.allCases) { f in
                    Button { withAnimation(.snappy(duration: 0.2)) { filter = f } } label: {
                        Text(f.rawValue)
                            .font(.onest(14.5, filter == f ? .semibold : .medium))
                            .foregroundStyle(filter == f ? Color.jInk : Color.jMute)
                            .padding(.vertical, 6)
                            .overlay(alignment: .bottom) {
                                if filter == f { Capsule().fill(Color.jCyan).frame(height: 2) }
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(Store.Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(sort.rawValue)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold))
                    }
                    .font(.onest(14.5, .medium))
                    .foregroundStyle(Color.jMute)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Inset.text)
        }
        .padding(.bottom, 10)
    }

    private var empty: some View {
        let filtered = !query.isEmpty || filter != .all
        return VStack(spacing: 10) {
            Image("QuoteMark").resizable().scaledToFit().frame(height: 44).foregroundStyle(Color.jCyan)
            Text(filtered ? "No matches" : "Nothing jotted yet").font(.onest(18, .semibold)).foregroundStyle(Color.jInk)
            Text(filtered ? "Nothing you've jotted fits that." : "Tap Link and paste a reel or video, or share it to Jot.")
                .font(.onest(14)).foregroundStyle(Color.jMute).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ item: Store.Item) -> some View {
        if selecting {
            let on = selected.contains(item.id)
            Button {
                if on { selected.remove(item.id) } else { selected.insert(item.id) }
            } label: {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 21))
                        .foregroundStyle(on ? Color.jCyanText : Color.jMute.opacity(0.6))
                        .contentTransition(.symbolEffect(.replace))
                    content(item)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.selection, trigger: on)
        } else {
            switch item {
            case .read(let read):
                // A tap, not a NavigationLink: a tap gives up once the finger moves, so a swipe never opens the row.
                ReadRow(read: read, query: query)
                    .onTapGesture {
                        if Find.trimmed(query).isEmpty { path.append(read) } else { path.append(FoundRead(read: read, query: query)) }
                    }
                    .accessibilityAddTraits(.isButton)
                    .contextMenu {
                        let text = read.markdown(timestamps: UserDefaults.standard.object(forKey: "includeTimestamps") as? Bool ?? true)
                        ShareLink(item: text) { Label("Send to Claude", systemImage: "paperplane") }
                        Button("Copy text", systemImage: "doc.on.doc") { Clipboard.copy(text) }
                        Button("Select", systemImage: "checkmark.circle") {
                            withAnimation(.snappy(duration: 0.25)) { selecting = true; selected = [item.id] }
                        }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) { store.delete(read) }
                    }
            case .request(let request):
                // A tap, not a NavigationLink: a tap gives up once the finger moves, so a swipe never opens the row.
                RequestRow(request: request)
                    .onTapGesture { path.append(request) }
                    .accessibilityAddTraits(.isButton)
                    .contextMenu {
                        if request.state == .failed { Button("Try again", systemImage: "arrow.clockwise") { store.retry(request) } }
                        Button("Remove", systemImage: "xmark", role: .destructive) { store.remove(request) }
                    }
            }
        }
    }

    @ViewBuilder private func content(_ item: Store.Item) -> some View {
        switch item {
        case .read(let read): ReadRow(read: read, query: query)
        case .request(let request): RequestRow(request: request)
        }
    }

    // MARK: Dock

    /// Record and Link float in glass at the bottom. Selecting swaps them for Delete.
    private var dock: some View {
        HStack(spacing: 10) {
            Spacer()
            if selecting {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label(selected.isEmpty ? "Delete" : "Delete \(selected.count)", systemImage: "trash")
                        .font(.onest(16, .bold))
                        .padding(.horizontal, 8)
                        .frame(height: 34)
                }
                .buttonStyle(.glassProminent)
                .tint(Color.jBad)
                .disabled(selected.isEmpty)
                .transition(.scale.combined(with: .opacity))
            } else {
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        #if os(iOS)
                        Button { recording = true } label: {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(Color.jInk)
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("Record a voice note")
                        #endif
                        Button { adding = true } label: {
                            Label("Link", systemImage: "link")
                                .font(.onest(16.5, .bold))
                                .foregroundStyle(Color.jOnCyan)
                                .padding(.horizontal, 8)
                                .frame(height: 34)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Color.jCyan)
                    }
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: selecting)
        .padding(.horizontal, Inset.edge)
        .padding(.bottom, 6)
    }
}

/// Swipe a row left to show Delete, the way iOS's own lists do: a system-red pill with a trash icon,
/// inset from the edge. There's no full-swipe delete; past the button the row only stretches a little.
/// One row open at a time; tapping an open row or scrolling closes it, and a swipe never opens the row.
private struct SwipeToDelete: ViewModifier {
    let id: String
    @Binding var open: String?
    var enabled: Bool
    var title: String
    var action: () -> Void
    @State private var drag: CGFloat = 0
    @State private var horizontal: Bool?
    @State private var gone = false
    @State private var width: CGFloat = 0
    private let button: CGFloat = 72
    private let gap: CGFloat = 12
    private var reveal: CGFloat { button + gap * 2 }

    private var resting: CGFloat { open == id ? -reveal : 0 }
    /// Follows the finger up to the button, then resists.
    private var x: CGFloat {
        if gone { return -width - 20 }
        let raw = min(0, resting + drag)
        return raw < -reveal ? -reveal - (-raw - reveal) * 0.25 : raw
    }
    private var swiping: Bool { horizontal == true || open == id }

    func body(content: Content) -> some View {
        if !enabled {
            content
        } else {
            content
                // Mid-swipe or open, the row underneath takes no taps, so it never opens by accident.
                .allowsHitTesting(!swiping)
                .overlay { if open == id { Color.clear.contentShape(Rectangle()).onTapGesture { close() } } }
                .offset(x: x)
                .background(alignment: .trailing) {
                    if x < 0 {
                        Button(action: remove) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: max(0, min(-x, reveal + 40) - gap * 2))
                                .frame(maxHeight: .infinity)
                                .background(Color.red, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                                .padding(.vertical, 10)
                                .padding(.horizontal, gap)
                                .opacity(min(1, -x / (reveal * 0.6)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(title)
                    }
                }
                .contentShape(Rectangle())
                .clipped()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                #if os(iOS)
                // A UIKit pan that only starts when the finger is moving sideways, the way iOS's own lists
                // decide. Anything more vertical is left to the scroll view, so scrolling and pull-to-refresh
                // never get swallowed by a swipe.
                .gesture(SidewaysPan { dx in
                    if horizontal != true {
                        horizontal = true
                        if open != nil, open != id { withAnimation(.snappy(duration: 0.25)) { open = nil } }
                    }
                    drag = dx
                } ended: { dx, velocity in
                    let landed = resting + dx + velocity * 0.08
                    withAnimation(.snappy(duration: 0.3)) {
                        open = landed < -reveal / 2 ? id : nil
                        drag = 0
                    }
                    // Let the touch finish before the row takes taps again.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { horizontal = nil }
                })
                #endif
                .accessibilityAction(named: title, remove)
        }
    }

    private func close() { withAnimation(.snappy(duration: 0.25)) { open = nil; drag = 0 } }

    private func remove() {
        withAnimation(.snappy(duration: 0.25)) { gone = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            open = nil
            drag = 0
            action()
            gone = false
        }
    }
}

#if os(iOS)
/// A pan that begins only for a mostly sideways movement and never runs alongside the scroll view.
private struct SidewaysPan: UIGestureRecognizerRepresentable {
    var changed: (CGFloat) -> Void
    var ended: (_ dx: CGFloat, _ velocity: CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let dx = pan.translation(in: pan.view).x
        switch pan.state {
        case .changed: changed(dx)
        case .ended, .cancelled, .failed: ended(dx, pan.velocity(in: pan.view).x)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y) * 1.5
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }
    }
}
#endif

/// Let go part-way through the fold and the scroll lands open or folded, whichever is nearer.
private struct FoldSnap: ScrollTargetBehavior {
    var range: CGFloat
    var insetTop: CGFloat
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let y = target.rect.minY + insetTop
        guard range > 0, y > 0, y < range else { return }
        target.rect.origin.y = (y < range / 2 ? 0 : range) - insetTop
    }
}

/// Words first: where it's from and how long, then a summary title, then the first lines said.
struct ReadRow: View {
    var read: Read
    /// While searching, the title and lines around the match are shown with the words marked.
    var query: String = ""
    @Environment(Store.self) private var store
    #if os(iOS)
    private var relistening: Bool { store.listeningAgain.contains(read.id) }
    #else
    private let relistening = false
    #endif
    var body: some View {
        let q = Find.trimmed(query)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                MediumIcon(read: read)
                (Text(read.handle ?? read.mediumName).foregroundStyle(Color.jInk)
                    + Text(read.handle == nil ? "" : " · \(read.mediumName)").foregroundStyle(Color.jMute))
                    .font(.onest(12.5, .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if relistening {
                    #if os(iOS)
                    HStack(spacing: 5) {
                        OrbView(kind: .listening, size: 16)
                        Text("Listening again").font(.onest(12, .semibold)).foregroundStyle(Color.jCyanText)
                    }
                    .transition(.opacity)
                    #endif
                } else if !q.isEmpty, case let n = Find.count(in: read.text, for: q), n > 0 {
                    Text(n == 1 ? "1 match" : "\(n) matches")
                        .font(.onest(12, .semibold))
                        .foregroundStyle(Color.jCyanText)
                } else if let d = read.duration {
                    Text(Read.clock(d)).font(.mono(11)).foregroundStyle(Color.jMute)
                }
            }
            Text(Find.marked(read.displayTitle, q))
                .font(.onest(16.5, .semibold))
                .foregroundStyle(Color.jInk)
                .lineLimit(2)
                .padding(.top, 8)
            let snippet = Find.snippet(in: read.text, for: q)
            let preview = snippet ?? read.preview
            if !preview.isEmpty {
                Text(snippet == nil ? AttributedString(preview) : Find.marked(preview, q))
                    .font(.onest(14))
                    .foregroundStyle(snippet == nil ? Color.jMute : Color.jInk.opacity(0.8))
                    .lineLimit(snippet == nil ? 2 : 3)
                    .lineSpacing(1.5)
                    .padding(.top, 3)
                    // The old words, faded while the careful listen works on them.
                    .opacity(relistening ? 0.45 : 1)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: relistening)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension Read {
    var mediumName: String {
        switch medium {
        case .reel: "Reel"
        case .post: "Post"
        case .short: "Short"
        case .video: site.map { "\($0) video" } ?? "Video"
        case .voiceMemo: "Voice memo"
        case .audio: "Audio"
        case .videoFile: "Video"
        case .link: site ?? "Link"
        }
    }
}

/// A small glyph for where a Read came from: the Instagram camera, YouTube's play button, a waveform for voice.
struct MediumIcon: View {
    var read: Read
    var size: CGFloat = 16
    var body: some View {
        Group {
            if read.site == "Instagram" {
                InstagramGlyph().stroke(Color.jInk, lineWidth: size * 0.1)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.82, weight: .semibold))
                    .foregroundStyle(read.kind == .file ? Color.jCyanText : Color.jInk)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(read.mediumName)
    }

    private var symbol: String {
        switch (read.medium, read.site) {
        case (_, "TikTok"): "music.note"
        case (_, "YouTube"): "play.rectangle.fill"
        case (.voiceMemo, _), (.audio, _): "waveform"
        case (.videoFile, _): "film"
        case (.video, _), (.short, _): "play.rectangle"
        default: "link"
        }
    }
}

/// Rounded square, lens and flash dot, drawn to sit with SF Symbols at the same size.
struct InstagramGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.06)
        var p = Path(roundedRect: r, cornerRadius: r.width * 0.3, style: .continuous)
        let lens = r.width * 0.23
        p.addEllipse(in: CGRect(x: r.midX - lens, y: r.midY - lens, width: lens * 2, height: lens * 2))
        let dot = r.width * 0.035
        let c = CGPoint(x: r.maxX - r.width * 0.24, y: r.minY + r.width * 0.24)
        p.addEllipse(in: CGRect(x: c.x - dot, y: c.y - dot, width: dot * 2, height: dot * 2))
        return p
    }
}

struct RequestRow: View {
    @Environment(Store.self) private var store
    var request: Request
    var body: some View {
            HStack(spacing: 12) {
                if request.state == .failed {
                    SourceBadge(site: nil, kind: request.fileName == nil && !request.link.hasSuffix(".m4a") ? .link : .file)
                } else {
                    OrbView(kind: request.state == .listening ? .listening : .searching, size: 34)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.state == .failed ? "Couldn't transcribe \(request.title ?? "this one")" : (request.title ?? request.link.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "www.", with: "")))
                        .font(.onest(16, .semibold))
                        .foregroundStyle(request.state == .failed ? Color.jBad : Color.jInk)
                        .lineLimit(1)
                    Group {
                        switch request.state {
                        case .waiting: Text(store.waitingLabel(request))
                        case .fetching: Text(request.runID != nil ? "Transcribing in the cloud" : request.via == "cloud" ? "Fetching in the cloud" : "Fetching on your Mac")
                        case .listening: Text("Listening · ") + Text("\(Int(request.progress * 100))%").font(.mono(11))
                        case .failed: Text(request.error ?? "Something went wrong.")
                        }
                    }
                    .font(.onest(13))
                    .foregroundStyle(Color.jMute)
                    .lineLimit(2)
                    if request.state == .listening {
                        ProgressBar(value: request.progress).padding(.top, 5)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

struct SourceBadge: View {
    var site: String?
    var kind: Read.Kind
    var body: some View {
        Group {
            if kind == .file {
                Image(systemName: "mic").font(.system(size: 14, weight: .semibold))
            } else {
                Text(abbrev).font(.onest(11, .bold))
            }
        }
        .foregroundStyle(Color.jMute)
        .frame(width: 34, height: 34)
        .background(Color.jSurface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    private var abbrev: String {
        switch site {
        case "Instagram": "IG"
        case "YouTube": "YT"
        case "TikTok": "TT"
        case "X": "X"
        default: "↗"
        }
    }
}

struct ProgressBar: View {
    var value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.jSurface2)
                Capsule().fill(Color.jCyan).frame(width: max(3, geo.size.width * value))
            }
        }
        .frame(height: 3)
    }
}

enum Clipboard {
    static var string: String? {
        #if os(iOS)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }

    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

extension Read: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension Request: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private extension View {
    /// The rows are the affordance; no list chevrons.
    @ViewBuilder func hideDisclosure() -> some View {
        #if os(iOS)
        navigationLinkIndicatorVisibility(.hidden)
        #else
        self
        #endif
    }
}

extension View {
    /// A clear glass button. On the Mac, .glass fills with the app's accent (Jot's cyan) whenever the window is
    /// in front, so there it's drawn as a plain button on a glass shape instead.
    @ViewBuilder func clearGlass(circle: Bool = false) -> some View {
        #if os(macOS)
        buttonStyle(ClearGlassStyle(circle: circle))
        #else
        if circle { buttonStyle(.glass).buttonBorderShape(.circle) } else { buttonStyle(.glass) }
        #endif
    }
}

#if os(macOS)
private struct ClearGlassStyle: ButtonStyle {
    var circle: Bool
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration, circle: circle) }

    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        let circle: Bool
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .foregroundStyle(circle ? Color.jInk : Color.jCyanText)   // Select reads cyan, as on the iPhone
                .padding(.horizontal, circle ? 4 : 12)
                .frame(minWidth: circle ? 30 : nil, minHeight: circle ? 30 : 28)
                .contentShape(circle ? AnyShape(Circle()) : AnyShape(Capsule()))
                .glassEffect(.regular.interactive(), in: circle ? AnyShape(Circle()) : AnyShape(Capsule()))
                .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
        }
    }
}
#endif
