#if os(macOS)
import JotCore
import SwiftUI

/// The Mac does the fetching: it watches Requests/ in the shared library, runs yt-dlp and whisper.cpp,
/// writes progress back into the request so the phone can show it, and saves the Read. One at a time.
@MainActor @Observable
final class Worker {
    enum Status: Equatable {
        case idle
        case needsSetup
        case settingUp(String)
        case working(title: String, state: Request.State, progress: Double)
    }

    private(set) var status: Status = .idle
    private(set) var lastError: String?
    /// Phone notifications: on, and the last setup or test result.
    var pushOn = PhonePush.configured
    var pushNote: String?
    private weak var store: Store?
    private var timer: Timer?
    private var transcriber: WhisperTranscriber?
    private var busy = false

    func start(store: Store) {
        guard self.store == nil else { return }
        self.store = store
        checkSetup()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.releaseWhisper() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    var ready: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: Paths.ytDLP.path) && fm.fileExists(atPath: Paths.whisperModel.path)
    }

    private func checkSetup() {
        if !ready { status = .needsSetup } else if status == .needsSetup { status = .idle }
    }

    func setUp() {
        guard case .needsSetup = status else { return }
        status = .settingUp("Starting…")
        Task {
            do {
                try await Setup.run { line in Task { @MainActor in self.status = .settingUp(line) } }
                status = .idle
            } catch {
                lastError = error.localizedDescription
                status = .needsSetup
            }
        }
    }

    /// Whisper's Metal device is torn down by a C++ static destructor during exit(), and it aborts if a model is
    /// still loaded. Free the model first; if a transcription still holds it, skip the destructors altogether
    /// (every file Jot writes is already on disk by then).
    private func releaseWhisper() {
        guard transcriber != nil else { return }
        if isKnownUniquelyReferenced(&transcriber) {
            transcriber = nil
        } else {
            _exit(0)
        }
    }

    /// One Whisper model in memory, shared by links and shared files (never two transcriptions at once).
    func whisper() throws -> WhisperTranscriber {
        if let transcriber { return transcriber }
        let t = try WhisperTranscriber()
        transcriber = t
        return t
    }

    private func tick() async {
        guard !busy, case .idle = status, let store, !store.runningLocal, let library = store.library else { return }
        // A phone that was closed mid cloud fetch leaves its request "running"; after 5 minutes the Mac takes it.
        let stale = { (r: Request) in
            r.via == "cloud" && r.state != .failed && Date.now.timeIntervalSince(r.updated ?? r.created) > (r.runID == nil ? 300 : 900)
        }
        // Listen again runs only in the cloud; the Mac never redoes those with the quick model.
        guard var next = library.loadRequests().filter({ $0.again != true && ($0.state == .waiting || stale($0)) }).min(by: { $0.created < $1.created }) else {
            // Nothing from the phone: transcribe anything shared to Jot on this Mac, with Whisper.
            if store.nextInboxFile() != nil, ready {
                store.startNextLocalJob(library: library) { [self] in try self.whisper() }
            }
            return
        }
        next.via = nil
        next.runID = nil
        busy = true
        defer { busy = false; status = .idle }
        await process(next, library: library)
        store.reload()
    }

    private func process(_ original: Request, library: Library) async {
        var request = original
        func update(_ state: Request.State, _ progress: Double = 0) {
            request.state = state
            request.progress = progress
            request.updated = .now
            try? library.save(request)
            status = .working(title: request.title ?? request.link, state: state, progress: progress)
            store?.reload()
        }
        update(.fetching)
        do {
            let transcriber = try whisper()
            let pipeline = Pipeline(readsFolder: library.reads)
            var lastWritten = -1.0
            let input = library.fileURL(for: request)?.path ?? request.link
            let (read, _) = try await pipeline.run(input, id: request.id, title: request.fileName == nil ? nil : request.title, transcriber: transcriber) { stage in
                Task { @MainActor in
                    switch stage {
                    case .listening(let p) where p - lastWritten >= 0.05 || p >= 1:
                        lastWritten = p
                        update(.listening, p)
                    case .decoding: update(.listening, 0)
                    default: break
                    }
                }
            }
            library.remove(request)
            lastError = nil
            await PhonePush.send("Transcript ready", read.displayTitle, readID: read.id, library: library)
        } catch {
            request.state = .failed
            request.error = error.localizedDescription
            request.updated = .now
            try? library.save(request)
            lastError = error.localizedDescription
            await PhonePush.send("Couldn't transcribe", "\(request.title ?? request.link): \(error.localizedDescription)", library: library)
        }
    }
}

/// The menu-bar window: what the Mac is doing right now.
struct WorkerMenu: View {
    @Environment(Store.self) private var store
    @Environment(Worker.self) private var worker
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image("Wordmark").resizable().scaledToFit().frame(height: 22)
                Spacer()
                Text(store.usingICloud ? "iCloud" : "This Mac").font(.onest(11, .semibold)).foregroundStyle(Color.jMute)
            }
            switch worker.status {
            case .idle:
                Text(waitingText).font(.onest(13)).foregroundStyle(Color.jMute).fixedSize(horizontal: false, vertical: true)
            case .needsSetup:
                Text("Jot needs yt-dlp and the Whisper model (about 500 MB) before it can transcribe.")
                    .font(.onest(13)).foregroundStyle(Color.jInk)
                Button("Set up Jot") { worker.setUp() }.buttonStyle(PrimaryButtonStyle())
            case .settingUp(let line):
                HStack { OrbView(kind: .searching, size: 34); Text(line).font(.onest(13)).foregroundStyle(Color.jInk) }
            case .working(let title, let state, let progress):
                HStack(spacing: 10) {
                    OrbView(kind: state == .listening ? .listening : .searching, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(state == .listening ? "Listening" : "Fetching").font(.onest(14, .semibold)).foregroundStyle(Color.jInk)
                        Text(title).font(.onest(12)).foregroundStyle(Color.jMute).lineLimit(1)
                        if state == .listening { ProgressBar(value: progress) }
                    }
                }
            }
            HStack {
                Text(worker.pushOn ? "Phone notifications on" : "Phone notifications off")
                    .font(.onest(12)).foregroundStyle(Color.jMute)
                Spacer()
                Button("Settings…") { NSApp.activate(); openSettings() }
                    .buttonStyle(.plain).font(.onest(12, .semibold)).foregroundStyle(Color.jInk)
            }
            if let err = worker.lastError {
                Text(err).font(.onest(12)).foregroundStyle(Color.jBad).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("Paste link") { store.add(link: Clipboard.string ?? "") }.buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain).font(.onest(13)).foregroundStyle(Color.jMute)
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(Color.jBg)
    }

    private var waitingText: String {
        let waiting = store.requests.filter { $0.state == .waiting }.count
        return waiting == 0 ? "Ready. Links you paste or share on your phone are transcribed here." : "\(waiting) waiting…"
    }
}

/// Jot › Settings… (⌘,) on the Mac.
struct MacSettings: View {
    @AppStorage(Appearance.key, store: Appearance.defaults) private var appearance = Appearance.system
    @Environment(Store.self) private var store
    @Environment(Worker.self) private var worker
    @State private var showDeleted = false

    var body: some View {
        @Bindable var worker = worker
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                LabeledContent("Status") {
                    Text(worker.pushOn ? "On" : "Off").foregroundStyle(worker.pushOn ? Color.jInk : Color.jMute)
                }
                if worker.pushOn {
                    LabeledContent("Key") { Text(PhonePush.keyID ?? "").font(.mono(12)) }
                    HStack {
                        Button("Send a test") {
                            guard let library = store.library else { return }
                            Task {
                                let n = await PhonePush.send("Jot", "Notifications from your Mac work.", library: library)
                                worker.pushNote = n > 0 ? "Sent to \(n) phone\(n == 1 ? "" : "s")." : "No phone took it. Open Jot on your iPhone once, then try again."
                            }
                        }
                        Button("Turn off") { PhonePush.turnOff(); worker.pushOn = false; worker.pushNote = nil }
                    }
                } else {
                    Button("Choose APNs key…") {
                        worker.pushNote = PhonePush.chooseKey()
                        worker.pushOn = PhonePush.configured
                    }
                }
                if let note = worker.pushNote {
                    Text(note).foregroundStyle(Color.jMute)
                }
            } header: {
                Text("Phone notifications")
            } footer: {
                Text("When this Mac finishes a transcript it tells your iPhone. Choose your AuthKey_XXXXXXXXXX.p8 from developer.apple.com › Keys; it's kept in your login keychain.")
                    .foregroundStyle(Color.jMute)
            }
            Section("Library") {
                LabeledContent("Saved in") { Text(store.usingICloud ? "iCloud" : "This Mac") }
                LabeledContent("Recently deleted") {
                    Button(store.deleted.isEmpty ? "Show" : "Show \(store.deleted.count)") { showDeleted = true }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showDeleted) { DeletedView().environment(store) }
        .font(.onest(13))
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
