import Foundation

/// The share extension's drop box: a folder in the App Group container that works offline.
/// The extension only writes here (it must stay small and fast); the app drains it on launch and every few seconds.
///
///     Inbox/<id>/item.json    what was shared
///     Inbox/<id>/<file>       the shared video or audio, if any
public struct Inbox: Sendable {
    public static let appGroup = "group.com.kezlahd.jot"

    public struct Item: Codable, Sendable, Identifiable, Equatable {
        public var id: String
        public var created: Date
        public var link: String?
        public var fileName: String?
        public var title: String?
        /// The GitHub run the share extension started for this link, if it could.
        public var runID: Int?
    }

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// nil when the App Group isn't available (unsigned builds).
    public static func shared() -> Inbox? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .map { Inbox(root: $0.appending(path: "Inbox", directoryHint: .isDirectory)) }
    }

    @discardableResult
    public func add(link: URL, title: String? = nil) throws -> Item {
        let item = Item(id: Inbox.makeID(), created: .now, link: link.absoluteString, fileName: nil, title: title)
        try write(item)
        return item
    }

    /// Copies the file in (the provider's copy is deleted when the extension returns).
    @discardableResult
    public func add(fileAt source: URL, title: String? = nil) throws -> Item {
        var item = Item(id: Inbox.makeID(), created: .now, link: nil, fileName: source.lastPathComponent, title: title)
        let folder = try makeFolder(item.id)
        let dest = folder.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: dest)
        item.fileName = dest.lastPathComponent
        try write(item)
        return item
    }

    public func save(_ item: Item) throws { try write(item) }

    public func items() -> [Item] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appending(path: "item.json")) else { return nil }
            return try? Inbox.decoder.decode(Item.self, from: data)
        }
        .sorted { $0.created < $1.created }
    }

    public func fileURL(for item: Item) -> URL? {
        item.fileName.map { root.appending(path: item.id, directoryHint: .isDirectory).appending(path: $0) }
    }

    public func remove(_ item: Item) {
        try? FileManager.default.removeItem(at: root.appending(path: item.id, directoryHint: .isDirectory))
    }

    // MARK: Private

    private func makeFolder(_ id: String) throws -> URL {
        let folder = root.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func write(_ item: Item) throws {
        let folder = try makeFolder(item.id)
        try Inbox.encoder.encode(item).write(to: folder.appending(path: "item.json"), options: .atomic)
    }

    static func makeID() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: .now) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

extension Inbox {
    /// Finds the first web link in shared text ("Check this out https://instagram.com/reel/…").
    public static func firstLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap(\.url).first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }
}
