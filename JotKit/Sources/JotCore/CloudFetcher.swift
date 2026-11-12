import Compression
import Foundation
import JotInbox

/// Fetches a link without the Mac: asks a GitHub Actions workflow in a private repo to run yt-dlp (logged out,
/// no cookies) and downloads the audio it hands back. See server/fetch.yml.
///
/// One run takes about 15 s. Instagram sometimes answers a runner with 429; a new run lands on another
/// machine, so that's retried.
public struct CloudFetcher: Sendable {
    public var repo: String   // "owner/name"
    public var token: String  // fine-grained token, Actions read and write on that repo only
    public var attempts = 3

    public init(repo: String, token: String) {
        self.repo = repo
        self.token = token
    }

    public func fetch(_ link: URL, id: String, into folder: URL) async throws -> Fetcher.Result {
        var lastError: Error = JotError.fetchFailed("the cloud fetch didn't run")
        for attempt in 1...attempts {
            do {
                return try await fetchOnce(link, runName: "\(id)-\(attempt)-\(UUID().uuidString.prefix(4))", into: folder)
            } catch let error as CloudError where error.retry {
                lastError = error.jotError(site: Fetcher.siteName(for: link))
            }
            catch let error as URLError {
                lastError = JotError.fetchFailed("the connection dropped (\(error.code.rawValue))")
            }
        }
        throw lastError
    }

    /// Checks the token and repo without running anything.
    public func check() async throws {
        _ = try await api("GET", "actions/workflows/fetch.yml")
    }

    // MARK: One run

    private static let debug = ProcessInfo.processInfo.environment["JOT_DEBUG"] != nil
    private static let t0 = Date.now
    static func log(_ s: @autoclosure () -> String) {
        if debug { FileHandle.standardError.write(Data(String(format: "[cloud %5.1fs] %@\n", Date.now.timeIntervalSince(t0), s()).utf8)) }
    }

    private func fetchOnce(_ link: URL, runName: String, into folder: URL) async throws -> Fetcher.Result {
        CloudFetcher.log("dispatch \(runName)")
        let runID = try await dispatch(link, runName: runName)
        // A run takes ~12 s once started; check often near the end.
        let deadline = Date.now.addingTimeInterval(240)
        var wait = 6.0
        while true {
            try await Task.sleep(for: .seconds(wait))
            wait = 2
            // A dropped connection (iOS suspends Jot, Wi-Fi blips) isn't a failed run: ask again.
            if case .done = (try? await state(of: runID)) ?? .running { break }
            if Date.now > deadline { throw CloudError(message: "the cloud fetch took too long", retry: false) }
        }
        return try await collect(runID, link: link, into: folder).result
    }

    // MARK: Pieces (the app collects runs the share extension started)

    public struct Collected: Sendable {
        public var result: Fetcher.Result
        /// Set when the runner transcribed it too.
        public var segments: [Read.Segment]?
        public var language: String?
        public var model: String?
        /// The model that proofread it on the runner, if it did.
        public var cleaned: String?
    }

    public enum RunState: Sendable, Equatable { case running, done }

    /// Starts a run. `transcribe` has the runner transcribe as well; `device` gets a push when it's finished.
    /// The slower, more careful model Listen again uses (the first pass is "small").
    public static let carefulModel = "large-v3-turbo"

    public func dispatch(_ link: URL, runName: String, transcribe: Bool = false, device: (token: String, sandbox: Bool)? = nil,
                         model: String? = nil) async throws -> Int {
        do {
            return try await CloudDispatch.start(repo: repo, token: token, link: link.absoluteString, runName: runName,
                                                 transcribe: transcribe, device: device, model: model)
        } catch CloudDispatch.Failure.refused(let code) {
            throw CloudFetcher.apiError(code, repo: repo)
        } catch CloudDispatch.Failure.noRun {
            throw CloudError(message: "GitHub didn't start the cloud fetch", retry: true)
        } catch CloudDispatch.Failure.network(let error) {
            throw error
        }
    }

    public func state(of runID: Int) async throws -> RunState {
        let run = try await api("GET", "actions/runs/\(runID)")
        CloudFetcher.log("poll: \(run["status"] as? String ?? "?")")
        if run["status"] as? String == "completed" { return .done }
        // The result is uploaded before the runner sends its push, a few seconds before GitHub marks the run
        // complete. Once it's there, collect it, so opening Jot from the push shows the transcript.
        let artifacts = try await api("GET", "actions/runs/\(runID)/artifacts")
        let uploaded = (artifacts["artifacts"] as? [[String: Any]])?.contains { $0["name"] as? String == "out" } ?? false
        return uploaded ? .done : .running
    }

    /// GitHub won't delete a run that's still finishing, so try for up to a minute.
    private func deleteRun(_ runID: Int) async {
        for _ in 0..<6 {
            if (try? await api("DELETE", "actions/runs/\(runID)")) != nil { return }
            try? await Task.sleep(for: .seconds(10))
        }
    }

    /// Downloads a finished run's audio, metadata and (if the runner made one) transcript, then deletes the run.
    public func collect(_ runID: Int, link: URL, into folder: URL) async throws -> Collected {
        defer { Task { [self] in await deleteRun(runID) } }
        let artifacts = try await api("GET", "actions/runs/\(runID)/artifacts")
        guard let artifact = (artifacts["artifacts"] as? [[String: Any]])?.first(where: { $0["name"] as? String == "out" }),
              let artifactID = artifact["id"] as? Int else {
            throw CloudError(message: "the cloud fetch returned nothing", retry: true)
        }
        CloudFetcher.log("downloading artifact")
        let files = try Zip.entries(in: try await download("actions/artifacts/\(artifactID)/zip"))

        // If the fetch worked the audio is kept even when the runner's transcription didn't; the phone transcribes it then.
        guard files["source.info.json"] != nil else {
            let stderr = files["error.txt"].map { String(decoding: $0, as: UTF8.self) } ?? ""
            let s = stderr.lowercased()
            if s.contains("429") || s.contains("too many requests") || s.contains("rate") {
                throw CloudError(message: "Instagram is busy", retry: true)
            }
            throw Fetcher.classify(stderr: stderr, site: Fetcher.siteName(for: link))
        }
        guard let infoData = files["source.info.json"],
              var info = try JSONSerialization.jsonObject(with: infoData) as? [String: Any],
              let (name, audio) = files.first(where: { $0.key.hasPrefix("source.") && !$0.key.hasSuffix(".json") }) else {
            throw CloudError(message: "the cloud fetch didn't produce audio", retry: true)
        }
        let media = folder.appending(path: name)
        try audio.write(to: media)
        info["requested_downloads"] = nil
        info["_filename"] = media.path
        var out = Collected(result: try Fetcher.result(from: info, folder: folder, link: link))
        if let data = files["transcript.json"], let t = try? JSONDecoder().decode(RunnerTranscript.self, from: data), !t.segments.isEmpty {
            out.segments = t.segments
            out.language = t.language
            out.model = t.model
            out.cleaned = t.cleaned
        }
        return out
    }

    private struct RunnerTranscript: Decodable {
        var language: String?
        var model: String?
        var cleaned: String?
        var segments: [Read.Segment]
    }

    static func apiError(_ code: Int, repo: String) -> Error {
        switch code {
        case 401: JotError.fetchFailed("the GitHub token was refused. Check it, or paste a new one in Cloud fetch.")
        case 403, 404: JotError.fetchFailed("GitHub can't see \(repo) with this token (HTTP \(code)).")
        default: CloudError(message: "GitHub answered HTTP \(code)", retry: code >= 500)
        }
    }

    // MARK: GitHub API

    private func request(_ method: String, _ path: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/\(path)")!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.timeoutInterval = 30
        req.cachePolicy = .reloadIgnoringLocalCacheData  // GitHub sends max-age=60; status polls must be fresh
        return req
    }

    @discardableResult
    private func api(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = request(method, path)
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw CloudFetcher.apiError(code, repo: repo) }
        return data.isEmpty ? [:] : ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
    }

    /// Artifact downloads redirect to blob storage, which must not see the GitHub token.
    private func download(_ path: String) async throws -> Data {
        let (_, response) = try await URLSession.shared.data(for: request("GET", path), delegate: NoRedirect())
        guard let http = response as? HTTPURLResponse, let location = http.value(forHTTPHeaderField: "Location"),
              let url = URL(string: location) else {
            throw CloudError(message: "the artifact wasn't ready", retry: true)
        }
        let (data, blob) = try await URLSession.shared.data(from: url)
        guard (blob as? HTTPURLResponse)?.statusCode == 200 else { throw CloudError(message: "the artifact download failed", retry: true) }
        return data
    }

    public struct CloudError: Error {
        var message: String
        var retry: Bool
        func jotError(site: String) -> JotError {
            message == "Instagram is busy" ? .fetchFailed("\(site) turned the cloud fetch away. Try again in a minute.") : .fetchFailed(message)
        }
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// Just enough ZIP to read a GitHub artifact: stored or deflated entries, sizes from the central directory.
enum Zip {
    static func entries(in data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard bytes.count >= 22,
              let eocd = stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1).first(where: { u32($0) == 0x06054b50 })
        else { throw JotError.fetchFailed("the cloud fetch returned a broken archive") }

        var out: [String: Data] = [:]
        var p = u32(eocd + 16)
        for _ in 0..<u16(eocd + 10) {
            guard p + 46 <= bytes.count, u32(p) == 0x02014b50 else { break }
            let method = u16(p + 10), compressed = u32(p + 20), size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32), local = u32(p + 42)
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen

            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compressed <= bytes.count else { continue }
            let raw = Array(bytes[start..<(start + compressed)])
            switch method {
            case 0: out[name] = Data(raw)
            case 8:
                if size == 0 { out[name] = Data(); continue }
                var buffer = [UInt8](repeating: 0, count: size)
                let n = compression_decode_buffer(&buffer, size, raw, raw.count, nil, COMPRESSION_ZLIB)  // raw DEFLATE
                if n == size { out[name] = Data(buffer) }
            default: continue
            }
        }
        return out
    }
}
