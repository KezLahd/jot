import Foundation

/// The shared folder both devices read and write (the iCloud container's Documents/, or a local folder).
///
///     Reads/<id>/read.json, transcript.md, source.*   finished transcripts
///     Requests/<id>.json                              links waiting for the Mac (with live progress)
///     Deleted/<id>/…                                  Recently deleted, purged after 30 days
public struct Library: Sendable {
    public let root: URL
    public var reads: URL { root.appending(path: "Reads", directoryHint: .isDirectory) }
    public var requests: URL { root.appending(path: "Requests", directoryHint: .isDirectory) }
    public var deleted: URL { root.appending(path: "Deleted", directoryHint: .isDirectory) }

    public static let keepDeletedFor: TimeInterval = 30 * 24 * 3600

    public init(root: URL) {
        self.root = root
    }

    public func prepare() throws {
        for url in [reads, requests, deleted] { try Paths.ensure(url) }
    }

    // MARK: Reads

    public func loadReads() -> [Read] {
        Library.subfolders(of: reads).compactMap { folder in
            Library.ensureDownloaded(folder.appending(path: "read.json"))
            return try? Read.load(from: folder)
        }
        .sorted { $0.created > $1.created }
    }

    public func folder(for read: Read) -> URL { reads.appending(path: read.id, directoryHint: .isDirectory) }

    public func audioURL(for read: Read) -> URL? {
        guard let name = read.audioFile else { return nil }
        let url = folder(for: read).appending(path: name)
        Library.ensureDownloaded(url)
        return url
    }

    /// Moves the Read to Recently deleted. Nothing is lost for 30 days.
    public func delete(_ read: Read) throws {
        try Paths.ensure(deleted)
        let dest = deleted.appending(path: read.id, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: dest)
        try coordinatedMove(from: folder(for: read), to: dest)
        try Data(ISO8601DateFormatter().string(from: .now).utf8).write(to: dest.appending(path: ".deleted-at"))
    }

    public func loadDeleted() -> [(read: Read, deletedAt: Date)] {
        Library.subfolders(of: deleted).compactMap { folder in
            guard let read = try? Read.load(from: folder) else { return nil }
            let stamp = (try? String(contentsOf: folder.appending(path: ".deleted-at"), encoding: .utf8)).flatMap { ISO8601DateFormatter().date(from: $0) }
            return (read, stamp ?? .now)
        }
        .sorted { $0.deletedAt > $1.deletedAt }
    }

    public func restore(_ read: Read) throws {
        let src = deleted.appending(path: read.id, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: src.appending(path: ".deleted-at"))
        try coordinatedMove(from: src, to: folder(for: read))
    }

    public func deleteForever(_ read: Read) throws {
        try FileManager.default.removeItem(at: deleted.appending(path: read.id, directoryHint: .isDirectory))
    }

    /// Permanently removes anything in Recently deleted for longer than 30 days.
    public func purgeExpired(now: Date = .now) {
        for item in loadDeleted() where now.timeIntervalSince(item.deletedAt) > Library.keepDeletedFor {
            try? deleteForever(item.read)
        }
    }

    // MARK: Requests

    public func addRequest(link: URL, title: String? = nil, id: String? = nil) throws -> Request {
        try Paths.ensure(requests)
        var request = Request(id: id ?? Pipeline.makeID(), link: link.absoluteString, created: .now)
        request.title = title
        try save(request)
        return request
    }

    /// Hands a file to the Mac when this device can't transcribe it. The file sits next to the request.
    public func addRequest(file: URL, id: String, title: String?, created: Date) throws -> Request {
        try Paths.ensure(requests)
        let name = "\(id).\(file.pathExtension.isEmpty ? "m4a" : file.pathExtension.lowercased())"
        try? FileManager.default.removeItem(at: requests.appending(path: name))
        try FileManager.default.copyItem(at: file, to: requests.appending(path: name))
        var request = Request(id: id, link: file.lastPathComponent, created: created)
        request.title = title
        request.fileName = name
        try save(request)
        return request
    }

    public func fileURL(for request: Request) -> URL? {
        guard let name = request.fileName else { return nil }
        let url = requests.appending(path: name)
        Library.ensureDownloaded(url)
        return url
    }

    public func loadRequests() -> [Request] {
        let files = (try? FileManager.default.contentsOfDirectory(at: requests, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> Request? in
            if url.lastPathComponent.hasPrefix(".") && url.pathExtension == "icloud" {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                return nil
            }
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
            return try? Read.decoder.decode(Request.self, from: data)
        }
        .sorted { $0.created > $1.created }
    }

    public func save(_ request: Request) throws {
        try Read.encoder.encode(request).write(to: requests.appending(path: "\(request.id).json"), options: .atomic)
    }

    public func remove(_ request: Request) {
        try? FileManager.default.removeItem(at: requests.appending(path: "\(request.id).json"))
        if let name = request.fileName { try? FileManager.default.removeItem(at: requests.appending(path: name)) }
    }

    // MARK: Helpers

    static func subfolders(of url: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    /// iCloud may hold only a placeholder; ask for the real file. A no-op for local folders.
    static func ensureDownloaded(_ url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    private func coordinatedMove(from: URL, to: URL) throws {
        var coordError: NSError?
        var moveError: Error?
        NSFileCoordinator().coordinate(writingItemAt: from, options: .forMoving, writingItemAt: to, options: .forReplacing, error: &coordError) { a, b in
            do { try FileManager.default.moveItem(at: a, to: b) } catch { moveError = error }
        }
        if let error = coordError ?? moveError { throw error }
    }
}

/// A link waiting for the Mac. The worker writes progress back into the same file so the phone can show it.
public struct Request: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable { case waiting, fetching, listening, failed }

    public var id: String
    public var link: String
    public var created: Date
    public var state: State = .waiting
    public var progress: Double = 0
    public var title: String?
    public var error: String?
    public var updated: Date?
    /// Set when the request is a shared file (sitting in Requests/) rather than a link.
    public var fileName: String?
    /// Who's working on it: nil for the Mac, "cloud" when the iPhone fetches it through GitHub.
    public var via: String?
    /// The GitHub run fetching (and transcribing) this link in the cloud.
    public var runID: Int?
    /// Listen again: the cloud is re-transcribing an existing Read (same id) with the larger Whisper model.
    /// When it's done the Read's lines are replaced; it never becomes a new Read.
    public var again: Bool? = nil

    public init(id: String, link: String, created: Date) {
        self.id = id; self.link = link; self.created = created
    }
}
