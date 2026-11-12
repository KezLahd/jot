import JotInbox
import SwiftUI
import UniformTypeIdentifiers

/// Share to Jot: takes a link (or text containing one) or a video/audio file, drops it in the Inbox, and closes.
/// Nothing heavy happens here; the app does the work.
enum ShareHandler {
    enum Outcome { case link, cloud, file, nothing, failed(String) }

    static func handle(_ items: [NSExtensionItem], found: @MainActor (String) -> Void) async -> Outcome {
        guard let inbox = Inbox.shared() else { return .failed("Jot's shared folder isn't available.") }
        let providers = items.flatMap { $0.attachments ?? [] }
        let title = items.compactMap { $0.attributedContentText?.string }.first { !$0.isEmpty && Inbox.firstLink(in: $0) == nil }

        // Files first: a shared screen recording often also carries a link to nowhere useful.
        for p in providers {
            for type in [UTType.movie, .audiovisualContent, .audio] where p.hasItemConformingToTypeIdentifier(type.identifier) {
                await found(type.conforms(to: .audio) ? "A voice memo" : "A video")
                if (try? await copyFile(p, type: type, into: inbox, title: title)) != nil { return .file }
            }
        }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, !url.isFileURL {
                await found(describe(url))
                return await addLink(url, title: title, inbox: inbox)
            }
        }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
               let url = Inbox.firstLink(in: text) {
                await found(describe(url))
                return await addLink(url, title: nil, inbox: inbox)
            }
        }
        return .nothing
    }

    /// What was shared, in a few words: "An Instagram reel", "A TikTok", "A YouTube Short".
    static func describe(_ url: URL) -> String {
        let host = (url.host() ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        let path = url.path().lowercased()
        if host.hasSuffix("instagram.com") { return path.hasPrefix("/reel") ? "An Instagram reel" : "An Instagram post" }
        if host.hasSuffix("tiktok.com") { return "A TikTok" }
        if host.hasSuffix("youtube.com") || host == "youtu.be" { return path.hasPrefix("/shorts") ? "A YouTube Short" : "A YouTube video" }
        if host == "x.com" || host.hasSuffix("twitter.com") { return "A post on X" }
        if host.hasSuffix("threads.net") || host.hasSuffix("threads.com") { return "A Threads post" }
        if host.hasSuffix("facebook.com") || host == "fb.watch" { return "A Facebook video" }
        return host.isEmpty ? "A link" : host
    }

    /// Queues the link, then (with cloud fetch set up) starts the GitHub run right away, so it's fetched,
    /// transcribed and pushed back as a notification without Jot being opened.
    private static func addLink(_ url: URL, title: String?, inbox: Inbox) async -> Outcome {
        guard var item = try? inbox.add(link: url, title: title) else { return .failed("Couldn't save the link.") }
        #if os(iOS)
        guard let token = CloudShared.token else { return .link }
        if let run = try? await CloudDispatch.start(repo: CloudShared.repo, token: token, link: url.absoluteString,
                                                    runName: item.id, transcribe: true, device: CloudShared.pushDevice, timeout: 8) {
            item.runID = run
            try? inbox.save(item)
            return .cloud
        }
        #endif
        return .link
    }

    private static func copyFile(_ provider: NSItemProvider, type: UTType, into inbox: Inbox, title: String?) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                // The file is only valid inside this callback, so copy it now.
                if let url {
                    do { try inbox.add(fileAt: url, title: title); cont.resume() } catch { cont.resume(throwing: error) }
                } else {
                    cont.resume(throwing: error ?? CocoaError(.fileNoSuchFile))
                }
            }
        }
    }
}

/// What the share sheet shows. It fills Jot's sheet with no card: what you shared sits between Jot's quote
/// marks, and once it's safely in the queue the quotes snap shut on it ("Jotted") and the sheet goes.
@MainActor @Observable final class ShareState {
    var found: String?
    var outcome: ShareHandler.Outcome?
    var landed: Date?
}

struct ShareScreen: View {
    var state: ShareState
    var close: () -> Void
    @State private var started = Date.now

    private var succeeded: Bool {
        switch state.outcome { case .link?, .cloud?, .file?: true; default: false }
    }

    var body: some View {
        VStack(spacing: 34) {
            Spacer()
            quotes
                .frame(width: 150, height: 56)
                .scaleEffect(2)
                .frame(height: 112)
            VStack(spacing: 8) {
                Text(headline)
                    .font(.onest(19, .semibold))
                    .foregroundStyle(Color.jInk)
                Text(detail)
                    .font(.onest(15))
                    .foregroundStyle(Color.jMute)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 40, alignment: .top)
            }
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.25), value: headline)
            .animation(.easeOut(duration: 0.25), value: detail)
            if !succeeded, state.outcome != nil {
                Button("Close", action: close)
                    .font(.onest(16, .semibold))
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.jBg.ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture { if state.outcome != nil { close() } }
        .sensoryFeedback(.impact(weight: .heavy, intensity: 0.8), trigger: state.landed) { _, new in new != nil }
    }

    /// Open quotes breathe while the link is saved, then the pull-to-refresh release plays with "Jotted".
    /// If it couldn't be added the quotes stay open and grey.
    @ViewBuilder private var quotes: some View {
        if let landed = state.landed {
            PullQuotes(pull: PullQuotes.threshold, refreshStart: landed, words: "Jotted")
        } else if state.outcome != nil {
            PullQuotes(pull: PullQuotes.threshold - 0.5)
        } else {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSince(started)
                PullQuotes(pull: PullQuotes.threshold + 14 * (1 - cos(t * 2.6)))
            }
        }
    }

    private var headline: String {
        switch state.outcome {
        case nil, .link?, .cloud?, .file?: state.found ?? "Adding to Jot"
        case .nothing?: "Nothing to jot here"
        case .failed?: "Couldn't add this"
        }
    }

    private var detail: String {
        switch state.outcome {
        case nil: "Adding to Jot…"
        case .cloud?: "Transcribing now. Jot will tell you when the words are ready."
        case .link?: "Jot fetches it next time it's open."
        case .file?: "Jot transcribes it next time it's open."
        case .nothing?: "Share a link, a video or a voice memo."
        case .failed(let why)?: why
        }
    }
}

extension ShareState {
    /// Runs the share, then closes once the quotes have snapped shut (or waits for Close if it failed).
    func run(_ items: [NSExtensionItem], close: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            let outcome = await ShareHandler.handle(items) { self.found = $0 }
            self.outcome = outcome
            switch outcome {
            case .link, .cloud, .file:
                landed = .now
                try? await Task.sleep(for: .seconds(PullQuotes.duration - 0.15))
                close()
            case .nothing, .failed: break
            }
        }
    }
}

#if os(iOS)
import UIKit

final class ShareViewController: UIViewController {
    private let state = ShareState()

    override func viewDidLoad() {
        super.viewDidLoad()
        let close: @MainActor () -> Void = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        let host = UIHostingController(rootView: ShareScreen(state: state, close: close))
        host.overrideUserInterfaceStyle = Appearance.current.style
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        state.run((extensionContext?.inputItems as? [NSExtensionItem]) ?? [], close: close)
    }
}
#else
import AppKit

final class ShareViewController: NSViewController {
    private let state = ShareState()

    override func loadView() {
        let close: @MainActor () -> Void = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        view = NSHostingView(rootView: ShareScreen(state: state, close: close))
        view.appearance = Appearance.current.nsAppearance
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 300)
        state.run((extensionContext?.inputItems as? [NSExtensionItem]) ?? [], close: close)
    }
}
#endif
