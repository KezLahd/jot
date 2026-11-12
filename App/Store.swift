import Foundation
import JotCore
import JotInbox
import Observation

/// The app's view of the shared library. Reads from iCloud when it's available, otherwise from a local folder.
@MainActor @Observable
final class Store {
    private(set) var library: Library?
    private(set) var reads: [Read] = []
    private(set) var requests: [Request] = []
    /// Listen again jobs, kept apart: they share their Read's id and never show as rows.
    private(set) var againRequests: [Request] = []
    private(set) var deleted: [(read: Read, deletedAt: Date)] = []
    private(set) var usingICloud = false
    /// Shared files being transcribed on this device, shown in the list like requests.
    private(set) var localJobs: [Request] = []
    var message: String?
    /// A Read to open, from a tapped notification.
    var openReadID: String?

    private let inbox = Inbox.shared()
    private var failedInbox: Set<String> = []
    /// Links the phone already tried through GitHub this session; if that failed they're the Mac's.
    private var cloudTried: Set<String> = []
    private(set) var runningLocal = false

    private var timer: Timer?

    #if os(iOS)
    /// The phone's Whisper model, downloaded once over Wi-Fi. Until then Apple's on-device speech is used.
    enum ModelState: Equatable { case missing, downloading(String), ready, failed(String) }
    private(set) var model: ModelState = Setup.isInstalled ? .ready : .missing
    private var whisper: PhoneWhisper?

    func downloadModelIfNeeded() {
        guard model == .missing || { if case .failed = model { true } else { false } }() else { return }
        model = .downloading("Waiting for Wi-Fi…")
        Task.detached {
            do {
                try await Setup.run(wifiOnly: true) { line in Task { @MainActor in self.model = .downloading(line) } }
                await MainActor.run { self.model = .ready }
            } catch {
                await MainActor.run { self.model = .failed(error.localizedDescription) }
            }
        }
    }

    /// Whisper when its model is on the phone, otherwise Apple's SpeechTranscriber.
    private func phoneTranscriber() async throws -> any Transcriber {
        guard model == .ready else { return AppleTranscriber() }
        if let whisper { return whisper }
        let w = try await Task.detached { PhoneWhisper(gpu: try WhisperTranscriber()) }.value  // a second or two; keep it off the main thread
        whisper = w
        return w
    }
    #endif

    func start() {
        guard library == nil else { return }
        Task {
            let icloud = await Task.detached { () -> URL? in
                FileManager.default.url(forUbiquityContainerIdentifier: Theme.iCloudContainer)?
                    .appending(path: "Documents", directoryHint: .isDirectory)
            }.value
            let root = icloud ?? Store.localRoot
            let library = Library(root: root)
            do { try library.prepare() } catch { message = "Couldn't open the library: \(error.localizedDescription)" }
            library.purgeExpired()
            self.library = library
            self.usingICloud = icloud != nil
            #if os(iOS)
            downloadModelIfNeeded()
            Notify.ask()
            AppDelegate.onToken = { [weak self] token in if let library = self?.library { PhoneDevice.save(token: token, in: library) } }
            if let token = AppDelegate.token { PhoneDevice.save(token: token, in: library) }
            AppDelegate.onOpen = { [weak self] id in self?.openReadID = id }
            openReadID = AppDelegate.pendingRead
            // Nothing runs before launch, so a cloud fetch still marked as running was cut off: release it.
            for var r in library.loadRequests() where r.via == "cloud" && r.state != .failed && r.runID == nil {
                r.state = .waiting; r.via = nil; r.progress = 0
                try? library.save(r)
            }
            #endif
            reload()
            // Cheap folder listing; picks up the Mac's progress and new Reads from iCloud.
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.reload() }
            }
        }
    }

    static var localRoot: URL {
        #if os(macOS)
        Paths.root  // the same folder the jot CLI uses
        #else
        URL.documentsDirectory.appending(path: "Jot", directoryHint: .isDirectory)
        #endif
    }

    /// Pull to refresh: check cloud runs now instead of waiting for their next poll.
    func refresh() {
        #if os(iOS)
        lastRunCheck.removeAll()
        #endif
        reload()
    }

    func reload() {
        guard let library else { return }
        drainInbox(into: library)
        let new = library.loadReads()
        if new != reads { reads = new }
        let all = library.loadRequests()
        let again = all.filter { $0.again == true }
        if again != againRequests { againRequests = again }
        let newRequests = localJobs + all.filter { req in req.again != true && !new.contains { $0.id == req.id } }
        if newRequests != requests { requests = newRequests }
        deleted = library.loadDeleted()
        fillSummaries(library)
    }

    // MARK: Summaries for older Reads

    private var summaryTried: Set<String> = []
    private var summarizing = false

    /// Reads made before summaries existed (or on a device without Apple Intelligence) get one, one at a time.
    private func fillSummaries(_ library: Library) {
        guard !summarizing, Headline.available,
              let read = reads.first(where: { $0.summary == nil && !summaryTried.contains($0.id) }) else { return }
        summarizing = true
        summaryTried.insert(read.id)
        Task {
            if let summary = await Headline.make(for: read), var fresh = try? Read.load(from: library.folder(for: read)), fresh.summary == nil {
                fresh.summary = summary
                try? fresh.write(to: library.folder(for: read))
            }
            summarizing = false
            reload()
        }
    }

    // MARK: Actions

    /// Adds a link for the Mac to fetch. Returns false if the text isn't a web link.
    @discardableResult
    func add(link text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil else {
            message = "That isn't a web link."
            return false
        }
        guard let library else { return false }
        do {
            _ = try library.addRequest(link: url)
            reload()
            return true
        } catch {
            message = "Couldn't save the link: \(error.localizedDescription)"
            return false
        }
    }

    func delete(_ read: Read) {
        guard let library else { return }
        do { try library.delete(read) } catch { message = "Couldn't delete: \(error.localizedDescription)" }
        reload()
    }

    func restore(_ read: Read) {
        guard let library else { return }
        do { try library.restore(read) } catch { message = "Couldn't restore: \(error.localizedDescription)" }
        reload()
    }

    func deleteForever(_ read: Read) {
        guard let library else { return }
        try? library.deleteForever(read)
        reload()
    }

    func retry(_ request: Request) {
        cloudTried.remove(request.id)
        if localJobs.contains(where: { $0.id == request.id }) {
            failedInbox.remove(request.id)
            localJobs.removeAll { $0.id == request.id }
            reload()
            return
        }
        guard let library else { return }
        var r = request
        r.state = .waiting
        r.error = nil
        r.progress = 0
        try? library.save(r)
        reload()
    }

    func remove(_ request: Request) {
        if localJobs.contains(where: { $0.id == request.id }) {
            localJobs.removeAll { $0.id == request.id }
            if let item = inbox?.items().first(where: { $0.id == request.id }) { inbox?.remove(item) }
            failedInbox.remove(request.id)
        }
        library?.remove(request)
        reload()
    }

    func audioURL(for read: Read) -> URL? { library?.audioURL(for: read) }

    // MARK: Share inbox (offline queue)

    /// Links go to the Mac's queue. Files are transcribed here, one at a time; on the Mac the Worker does that with Whisper.
    private func drainInbox(into library: Library) {
        guard let inbox else { return }
        for item in inbox.items() {
            if let link = item.link, let url = URL(string: link) {
                guard var request = try? library.addRequest(link: url, title: item.title, id: item.id) else { continue }
                if let run = item.runID {  // the share extension already started the cloud run
                    request.runID = run
                    request.via = "cloud"
                    request.state = .fetching
                    request.updated = .now
                    try? library.save(request)
                }
                inbox.remove(item)
            }
        }
        #if os(iOS)
        startNextLocalJob(library: library) { [unowned self] in try await self.phoneTranscriber() }
        startNextCloudJob(library: library)
        collectCloudRuns(library: library)
        #endif
    }

    /// The next shared file waiting in the inbox, if nothing is running.
    func nextInboxFile() -> (item: Inbox.Item, file: URL)? {
        guard !runningLocal, let inbox else { return nil }
        for item in inbox.items() where item.fileName != nil && !failedInbox.contains(item.id) {
            if let file = inbox.fileURL(for: item) { return (item, file) }
        }
        return nil
    }

    func startNextLocalJob(library: Library, transcriber: @escaping () async throws -> any Transcriber) {
        guard let (item, file) = nextInboxFile() else { return }
        runningLocal = true
        var job = Request(id: item.id, link: item.fileName ?? "File", created: item.created)
        job.title = item.title ?? file.deletingPathExtension().lastPathComponent
        job.state = .listening
        localJobs = [job]
        #if os(iOS)
        let background = BackgroundJob(title: job.title ?? "Shared file")
        #endif
        Task {
            do {
                let pipeline = Pipeline(readsFolder: library.reads)
                let (read, _) = try await pipeline.run(file.path, id: item.id, title: job.title, transcriber: try await transcriber()) { stage in
                    if case .listening(let p) = stage {
                        Task { @MainActor in
                            if let i = self.localJobs.firstIndex(where: { $0.id == item.id }) { self.localJobs[i].progress = p }
                            #if os(iOS)
                            background.update(p)
                            #endif
                        }
                    }
                }
                inbox?.remove(item)
                localJobs.removeAll { $0.id == item.id }
                #if os(iOS)
                background.finish(success: true)
                Notify.post("Transcript ready", read.displayTitle, readID: read.id)
                #endif
            } catch {
                #if os(iOS)
                background.finish(success: false)
                #endif
                // A file with no sound is final. Anything else (no on-device speech model, the simulator, an
                // analyzer error) goes to the Mac, which transcribes it with Whisper.
                let final = { if case JotError.noAudio = error { return true }; if case JotError.decodeFailed = error { return true }; return false }()
                if !final, (try? library.addRequest(file: file, id: item.id, title: job.title, created: item.created)) != nil {
                    inbox?.remove(item)
                    localJobs.removeAll { $0.id == item.id }
                } else {
                    failedInbox.insert(item.id)
                    job.state = .failed
                    job.error = error.localizedDescription
                    localJobs = [job]
                    #if os(iOS)
                    Notify.post("Couldn't transcribe", "\(job.title ?? "Shared file"): \(error.localizedDescription)")
                    #endif
                }
            }
            runningLocal = false
            reload()
        }
    }

    func waitingLabel(_ r: Request) -> String {
        #if os(iOS)
        if r.fileName == nil, cloudReady, !cloudTried.contains(r.id) { return "Waiting" }
        #endif
        return "Waiting for your Mac"
    }

    // MARK: Cloud fetch (iPhone)

    #if os(iOS)
    private(set) var cloudReady = CloudSettings.fetcher != nil

    func cloudSettingsChanged() {
        cloudReady = CloudSettings.fetcher != nil
        cloudTried.removeAll()
        reload()
    }

    private var collecting = false
    private var lastRunCheck: [String: Date] = [:]

    /// Links the share extension sent to the cloud: when the run finishes, save the transcript it made.
    /// (The runner already sent the notification.) If it failed for a reason the Mac might not hit, the link
    /// goes back to waiting and is fetched the usual way.
    private func collectCloudRuns(library: Library) {
        guard !collecting, let cloud = CloudSettings.fetcher,
              var request = library.loadRequests().first(where: {
                  $0.runID != nil && $0.state != .failed && Date.now.timeIntervalSince(lastRunCheck[$0.id] ?? .distantPast) > 4
              }),
              let run = request.runID, let link = URL(string: request.link) else { return }
        collecting = true
        lastRunCheck[request.id] = .now
        Task {
            defer { collecting = false }
            if request.again == true {
                await collectAgain(request, run: run, link: link, cloud: cloud, library: library)
                return
            }
            do {
                guard try await cloud.state(of: run) == .done else { return }
                let folder = library.reads.appending(path: request.id, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let collected = try await cloud.collect(run, link: link, into: folder)
                _ = try await Pipeline(readsFolder: library.reads).save(collected, id: request.id)
                library.remove(request)
            } catch is URLError {
                return  // offline for a moment; try again on the next pass
            } catch {
                try? FileManager.default.removeItem(at: library.reads.appending(path: request.id, directoryHint: .isDirectory))
                let final: Bool = switch error as? JotError {
                case .needsLogin, .unavailable, .noAudio: true
                default: false
                }
                request.runID = nil
                request.via = nil
                request.progress = 0
                request.updated = .now
                if final {
                    request.state = .failed
                    request.error = error.localizedDescription
                } else {
                    request.state = .waiting
                }
                try? library.save(request)
            }
            reload()
        }
    }

    // MARK: Listen again

    /// Transcripts the cloud is listening to again with the careful model.
    var listeningAgain: Set<String> { Set(againRequests.filter { $0.again == true && $0.state != .failed }.map(\.id)) }
    var listenAgainError: [String: String] { Dictionary(againRequests.filter { $0.again == true && $0.state == .failed }.map { ($0.id, $0.error ?? "") }, uniquingKeysWith: { a, _ in a }) }

    /// Has the cloud fetch the link again and transcribe it with the larger model (and beam search), which
    /// hears fast, mumbled or noisy speech far better than the quick first pass. The lines are swapped in when
    /// it's done, and a notification says so. Links only: files and voice memos have nothing to re-fetch.
    func listenAgain(_ read: Read) {
        guard let library, let cloud = CloudSettings.fetcher, read.kind == .link, let link = URL(string: read.source) else { return }
        var request = Request(id: read.id, link: read.source, created: .now)
        request.again = true
        request.via = "cloud"
        request.state = .listening
        request.title = read.displayTitle
        request.updated = .now
        try? library.save(request)
        reload()
        Task {
            do {
                request.runID = try await cloud.dispatch(link, runName: read.id, transcribe: true,
                                                         device: CloudShared.pushDevice, model: CloudFetcher.carefulModel)
                request.updated = .now
                try? library.save(request)
            } catch {
                request.state = .failed
                request.error = error.localizedDescription
                try? library.save(request)
            }
            reload()
        }
    }

    func dismissListenAgainError(_ id: String) {
        guard let library, let r = library.loadRequests().first(where: { $0.id == id && $0.again == true }) else { return }
        library.remove(r)
        reload()
    }

    private func collectAgain(_ original: Request, run: Int, link: URL, cloud: CloudFetcher, library: Library) async {
        var request = original
        guard let read = reads.first(where: { $0.id == request.id }) else { library.remove(request); reload(); return }
        do {
            guard try await cloud.state(of: run) == .done else { return }
            // Collect into a scratch folder; only the new lines move into the Read.
            let scratch = FileManager.default.temporaryDirectory.appending(path: "again-\(read.id)", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: scratch)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let collected = try await cloud.collect(run, link: link, into: scratch)
            _ = try await Pipeline(readsFolder: library.reads).relisten(read, with: collected)
            library.remove(request)
        } catch is URLError {
            return
        } catch {
            request.state = .failed
            request.runID = nil
            request.error = error.localizedDescription
            try? library.save(request)
        }
        reload()
    }

    /// Takes the oldest waiting link, has GitHub fetch the audio (logged out) and transcribes it here.
    /// If that fails for a reason the Mac might not hit, the request goes back to waiting for the Mac.
    private func startNextCloudJob(library: Library) {
        guard !runningLocal, let cloud = CloudSettings.fetcher else { return }
        guard var request = library.loadRequests()
            .filter({ $0.state == .waiting && $0.fileName == nil && !cloudTried.contains($0.id) })
            .min(by: { $0.created < $1.created }) else { return }
        runningLocal = true
        cloudTried.insert(request.id)
        request.state = .fetching
        request.via = "cloud"
        request.updated = .now
        try? library.save(request)
        let background = BackgroundJob(title: request.title ?? URL(string: request.link)?.host() ?? "Link")
        Task {
            // Fetching has no progress of its own (~15 s on GitHub); creep so iOS sees the job moving.
            let creep = Task { @MainActor in
                var f = 0.0
                while !Task.isCancelled && f < 0.25 { f += 0.02; background.update(f); try? await Task.sleep(for: .seconds(1.5)) }
            }
            var lastWritten = -1.0
            @MainActor func update(_ state: Request.State, _ progress: Double) {
                request.state = state
                request.progress = progress
                request.updated = .now
                try? library.save(request)
                reload()
            }
            do {
                let transcriber = try await phoneTranscriber()
                let pipeline = Pipeline(readsFolder: library.reads, cloud: cloud)
                let (read, _) = try await pipeline.run(request.link, id: request.id, transcriber: transcriber) { stage in
                    Task { @MainActor in
                        switch stage {
                        case .listening(let p) where p - lastWritten >= 0.05 || p >= 1:
                            lastWritten = p
                            update(.listening, p)
                            background.update(0.3 + 0.7 * p, title: "Transcribing")
                        case .decoding:
                            creep.cancel()
                            update(.listening, 0)
                            background.update(0.3, title: "Transcribing")
                        default: break
                        }
                    }
                }
                creep.cancel()
                library.remove(request)
                background.finish(success: true)
                Notify.post("Transcript ready", read.displayTitle, readID: read.id)
            } catch {
                creep.cancel()
                background.finish(success: false)
                let final: Bool = switch error as? JotError {
                case .needsLogin, .unavailable, .noAudio: true
                default: false
                }
                if final {
                    request.state = .failed
                    request.error = error.localizedDescription
                    Notify.post("Couldn't transcribe", error.localizedDescription)
                } else {
                    request.state = .waiting  // the Mac picks it up
                    request.via = nil
                    request.error = nil
                    request.progress = 0
                }
                request.updated = .now
                try? library.save(request)
            }
            runningLocal = false
            reload()
        }
    }
    #endif

    // MARK: Grouping

    enum Item: Identifiable, Equatable {
        case read(Read)
        case request(Request)
        var id: String {
            switch self {
            case .read(let r): "r-\(r.id)"
            case .request(let r): "q-\(r.id)"
            }
        }
        var date: Date {
            switch self {
            case .read(let r): r.created
            case .request(let r): r.created
            }
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", links = "Links", voice = "Voice", files = "Files"
        var id: String { rawValue }
        func keeps(_ r: Read) -> Bool {
            switch self {
            case .all: true
            case .links: r.kind == .link
            case .voice: r.medium == .voiceMemo || r.medium == .audio
            case .files: r.kind == .file && r.medium != .voiceMemo && r.medium != .audio
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case newest = "Newest", oldest = "Oldest", longest = "Longest", shortest = "Shortest", title = "A–Z"
        var id: String { rawValue }
        /// Date sorts get day headings; the rest are one run.
        var byDay: Bool { self == .newest || self == .oldest }
    }

    /// Everything the list shows, in order. Jobs still running sit on top unless you're searching or filtering.
    func items(matching query: String, filter: Filter = .all, sort: Sort = .newest) -> [Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var reads = self.reads.filter { r in
            filter.keeps(r) && (q.isEmpty || Find.matches(r.title, q) || Find.matches(r.summary ?? "", q) || (r.handle ?? "").lowercased().contains(q) || Find.matches(r.text, q))
        }
        switch sort {
        case .newest: reads.sort { $0.created > $1.created }
        case .oldest: reads.sort { $0.created < $1.created }
        case .longest: reads.sort { ($0.duration ?? 0) > ($1.duration ?? 0) }
        case .shortest: reads.sort { ($0.duration ?? .infinity) < ($1.duration ?? .infinity) }
        case .title: reads.sort { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        }
        let jobs: [Item] = q.isEmpty && filter == .all ? requests.sorted { $0.created > $1.created }.map { .request($0) } : []
        return jobs + reads.map { .read($0) }
    }

    /// Day headings for a run of items already in order.
    static func byDay(_ items: some Sequence<Item>) -> [(day: String, items: [Item])] {
        var out: [(day: String, items: [Item])] = []
        for item in items {
            let day = item.date.dayLabel
            if out.last?.day == day { out[out.count - 1].items.append(item) } else { out.append((day, [item])) }
        }
        return out
    }

    /// Bulk delete: Reads go to Recently deleted, jobs are dropped. One reload at the end.
    func delete(_ items: [Item]) {
        guard let library else { return }
        var failed = 0
        for item in items {
            switch item {
            case .read(let read): do { try library.delete(read) } catch { failed += 1 }
            case .request(let request):
                if localJobs.contains(where: { $0.id == request.id }) {
                    localJobs.removeAll { $0.id == request.id }
                    if let job = inbox?.items().first(where: { $0.id == request.id }) { inbox?.remove(job) }
                    failedInbox.remove(request.id)
                }
                library.remove(request)
            }
        }
        if failed > 0 { message = "Couldn't delete \(failed) of them." }
        reload()
    }
}
