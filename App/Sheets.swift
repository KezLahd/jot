import JotCore
import SwiftUI
import UniformTypeIdentifiers

/// A link in progress: the listening orb while the Mac works, or the reason it failed with a retry.
struct RequestView: View {
    var requestID: String
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let request = store.requests.first { $0.id == requestID }
        let read = store.reads.first { $0.id == requestID }
        Group {
            if let read {
                ReadView(read: read)
            } else if let request {
                VStack(spacing: 0) {
                    Spacer().frame(height: 30)
                    if request.state == .failed {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 54)).foregroundStyle(Color.jBad)
                            .frame(height: 170)
                    } else {
                        OrbView(kind: request.state == .listening ? .listening : .searching, size: 170)
                    }
                    Text(title(request)).font(.onest(24, .bold)).foregroundStyle(Color.jInk).padding(.top, 14)
                    Text(request.title ?? request.link)
                        .font(.onest(14.5)).foregroundStyle(Color.jMute).lineLimit(2).multilineTextAlignment(.center).padding(.top, 4)
                    if request.state == .listening {
                        ProgressBar(value: request.progress).frame(width: 220).padding(.top, 14)
                    }
                    if request.state == .failed {
                        Text(request.error ?? "").font(.onest(15)).foregroundStyle(Color.jInk).multilineTextAlignment(.center).padding(.top, 18)
                        HStack {
                            Button("Try again") { store.retry(request) }.buttonStyle(PrimaryButtonStyle())
                            Button("Remove") { store.remove(request); dismiss() }.buttonStyle(SecondaryButtonStyle())
                        }
                        .padding(.top, 18)
                    }
                    Spacer()
                    Text(request.state == .failed ? "" : request.runID != nil ? "Running in the cloud · you'll get a notification" : request.via == "cloud" ? "Running on this iPhone · you can leave Jot" : "Running on your Mac · you can close Jot")
                        .font(.onest(13)).foregroundStyle(Color.jMute).padding(.bottom, 20)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity)
                .background(Color.jBg)
            } else {
                Text("This one's gone.").font(.onest(16)).foregroundStyle(Color.jMute)
            }
        }
    }

    private func title(_ r: Request) -> String {
        switch r.state {
        case .waiting: store.waitingLabel(r)
        case .fetching: "Fetching"
        case .listening: "Listening"
        case .failed: "Couldn't transcribe"
        }
    }
}

/// Send to Claude first, then copy or save.
struct SendSheet: View {
    var read: Read
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage("includeTimestamps") private var timestamps = true
    @AppStorage("sendAsFile") private var asFile = false
    @State private var exporting = false
    @State private var note: String?

    private var text: String { read.markdown(timestamps: timestamps) }

    private var file: URL { read.markdownFile(timestamps: timestamps) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Send transcript").font(.onest(19, .bold)).foregroundStyle(Color.jInk).padding(.bottom, 12)
            sendToClaude
            option("Include timestamps", "clock") { Toggle("", isOn: $timestamps).labelsHidden().tint(Color.jCyan) }
            #if os(iOS)
            option("Send as a file", "doc.text") { Toggle("", isOn: $asFile).labelsHidden().tint(Color.jCyan) }
            Button(action: openInClaude) {
                option("Open in Claude", "arrow.up.forward.app") { Text("also copies it").font(.onest(13)).foregroundStyle(Color.jMute) }
            }.buttonStyle(.plain)
            #endif
            Button { Clipboard.copy(text); dismiss() } label: {
                option("Copy text", "doc.on.doc") { Text("\(read.wordCount) words").font(.onest(13)).foregroundStyle(Color.jMute) }
            }.buttonStyle(.plain)
            Button { exporting = true } label: {
                option("Save as Markdown", "doc") { Text(".md").font(.onest(13)).foregroundStyle(Color.jMute) }
            }.buttonStyle(.plain)
            ShareLink(item: text) { option("More…", "square.and.arrow.up") { EmptyView() } }.buttonStyle(.plain)
        }
        .padding(18)
        .background(Color.jSurface)
        .presentationDetents([.height(sheetHeight)])
        .presentationBackground(Color.jSurface)
        .alert("Couldn't open Claude", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) {
            Button("OK") { note = nil; dismiss() }
        } message: { Text(note ?? "") }
        .fileExporter(isPresented: $exporting, document: MarkdownFile(text: text), contentType: .plainText,
                      defaultFilename: read.title.prefix(60) + ".md") { _ in dismiss() }
        #if os(macOS)
        .frame(width: 420)
        #endif
    }

    @ViewBuilder private var sendToClaude: some View {
        #if os(macOS)
        // Claude Desktop takes a prefilled prompt (about 14k characters). Longer ones go via the clipboard.
        Button {
            if text.count < 12_000, let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: "claude://claude.ai/new?q=\(q)") {
                openURL(url)
            } else {
                Clipboard.copy(text)
                if let url = URL(string: "claude://claude.ai/new") { openURL(url) }
            }
            dismiss()
        } label: { sendLabel }
        .buttonStyle(.plain)
        #else
        // On iPhone, Claude appears in the share sheet. Text is what Anthropic documents; the file is the test.
        if asFile {
            ShareLink(item: file) { sendLabel }.buttonStyle(.plain)
        } else {
            ShareLink(item: text) { sendLabel }.buttonStyle(.plain)
        }
        #endif
    }

    private var sheetHeight: CGFloat {
        #if os(iOS)
        468
        #else
        400
        #endif
    }

    #if os(iOS)
    /// Claude's prefill link is only documented for the desktop app. Try it on iPhone, with the transcript on the
    /// clipboard as well, so if the app opens with an empty message you can paste it.
    private func openInClaude() {
        Clipboard.copy(text)
        let q = text.count < 12_000 ? text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) : nil
        guard let url = URL(string: q.map { "claude://claude.ai/new?q=\($0)" } ?? "claude://claude.ai/new") else { return }
        openURL(url) { opened in
            if opened { dismiss() } else { note = "The Claude app isn't installed. The transcript is on your clipboard." }
        }
    }
    #endif

    private var sendLabel: some View {
        HStack(spacing: 8) {
            Image("QuoteMark").resizable().scaledToFit().frame(height: 18)
            Text("Send to Claude")
        }
        .font(.onest(16.5, .semibold))
        .foregroundStyle(Color.jOnCyan)
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .background(Color.jCyan, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.bottom, 6)
    }

    private func option<Trailing: View>(_ title: String, _ icon: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color.jInk)
                .frame(width: 34, height: 34)
                .background(Color.jSurface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(title).font(.onest(16.5, .medium)).foregroundStyle(Color.jInk)
            Spacer()
            trailing()
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

struct MarkdownFile: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Recently deleted: restore, or delete now. Anything older than 30 days is removed automatically.
struct DeletedView: View {
    /// Pushed from Settings rather than shown as its own sheet: no stack of its own, and no Done.
    var pushed = false
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Stacked(pushed) {
            List {
                Text("Transcripts stay here for 30 days, then they're removed.")
                    .font(.onest(13)).foregroundStyle(Color.jMute)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                ForEach(store.deleted, id: \.read.id) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        ReadRow(read: item.read)
                        HStack {
                            Text(daysLeft(item.deletedAt)).font(.onest(12.5)).foregroundStyle(Color.jMute)
                            Spacer()
                            Button("Restore") { store.restore(item.read) }.buttonStyle(SecondaryButtonStyle())
                            Button("Delete now", role: .destructive) { store.deleteForever(item.read) }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.jBg)
            .navigationTitle("Recently deleted")
            .toolbar { if !pushed { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func daysLeft(_ deletedAt: Date) -> String {
        let left = max(0, Int(ceil((Library.keepDeletedFor - Date.now.timeIntervalSince(deletedAt)) / 86_400)))
        return left == 1 ? "1 day left" : "\(left) days left"
    }
}

#if os(iOS)
/// Paste a GitHub token once; links are then fetched by the private jot-fetcher workflow, logged out.
struct CloudSettingsView: View {
    var pushed = false
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var repo = CloudSettings.repo
    @State private var token = ""
    @State private var checking = false
    @State private var result: String?
    @State private var hasToken = CloudSettings.token != nil

    var body: some View {
        Stacked(pushed) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Links are fetched by a private GitHub workflow, so your Mac can be asleep. It never signs in to Instagram: it only sees what a logged-out visitor sees, and your account is never used.")
                        .font(.onest(14)).foregroundStyle(Color.jMute)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Repo").font(.onest(13, .semibold)).foregroundStyle(Color.jInk)
                        TextField("owner/jot-fetcher", text: $repo)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.mono(14)).padding(12)
                            .background(Color.jSurface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("GitHub token").font(.onest(13, .semibold)).foregroundStyle(Color.jInk)
                        SecureField(hasToken ? "Saved. Paste to replace it." : "github_pat_…", text: $token)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.mono(14)).padding(12)
                            .background(Color.jSurface, in: RoundedRectangle(cornerRadius: 12))
                        Text("Kept in this iPhone's Keychain.").font(.onest(12)).foregroundStyle(Color.jMute)
                    }

                    HStack(spacing: 10) {
                        Button(checking ? "Checking…" : "Save and check") { save() }
                            .buttonStyle(PrimaryButtonStyle()).disabled(checking)
                        if hasToken {
                            Button("Turn off", role: .destructive) {
                                CloudSettings.token = nil
                                hasToken = false
                                result = "Cloud fetch is off. Links wait for your Mac."
                                store.cloudSettingsChanged()
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    if let result {
                        Text(result).font(.onest(13)).foregroundStyle(Color.jInk).fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Making the token").font(.onest(13, .semibold)).foregroundStyle(Color.jInk)
                        Text("""
                        1. github.com → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token.
                        2. Repository access: Only select repositories → jot-fetcher.
                        3. Permissions → Actions: Read and write. Nothing else.
                        4. Copy the token and paste it above.
                        """)
                        .font(.onest(13)).foregroundStyle(Color.jMute)
                    }
                    .padding(14)
                    .background(Color.jSurface, in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(20)
            }
            .background(Color.jBg)
            .navigationTitle("Cloud fetch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { if !pushed { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } } }
        }
    }

    private func save() {
        CloudSettings.repo = repo
        let pasted = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = pasted.isEmpty ? CloudSettings.token : pasted
        guard let candidate, !candidate.isEmpty else { result = "Paste a token first."; return }
        checking = true
        result = nil
        Task {
            do {
                try await CloudFetcher(repo: CloudSettings.repo, token: candidate).check()
                CloudSettings.token = candidate
                hasToken = true
                token = ""
                result = "Connected. Links you share now finish on this iPhone."
                store.cloudSettingsChanged()
            } catch JotError.fetchFailed(let why) {
                result = why.prefix(1).uppercased() + why.dropFirst()
            } catch {
                result = error.localizedDescription
            }
            checking = false
        }
    }
}
#endif

extension Read {
    /// The transcript as a .md file in temp, named after the summary, for apps that take files better than text.
    func markdownFile(timestamps: Bool) -> URL {
        let name = displayTitle.replacingOccurrences(of: "/", with: "-").prefix(60)
        let url = URL.temporaryDirectory.appending(path: "\(name).md")
        try? markdown(timestamps: timestamps).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Its own NavigationStack when shown as a sheet; none when pushed inside another stack.
struct Stacked<Content: View>: View {
    let pushed: Bool
    @ViewBuilder var content: Content
    init(_ pushed: Bool, @ViewBuilder content: () -> Content) { self.pushed = pushed; self.content = content() }
    var body: some View {
        if pushed { content } else { NavigationStack { content } }
    }
}
