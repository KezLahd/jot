import JotCore
import SwiftUI

/// Tap Link: paste a link, Jot thinks for a moment, says where it's from and whether it can open it.
/// Jot only lights up for links a logged-out visitor can see.
struct LinkSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var checking = false
    @FocusState private var focused: Bool

    private var verdict: LinkCheck { LinkCheck.check(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a link").font(.onest(20, .bold)).foregroundStyle(Color.jInk)

            HStack(spacing: 8) {
                TextField("Paste a reel or video link", text: $text)
                    .font(.onest(15.5))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .submitLabel(.go)
                    .onSubmit(add)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .background(Color.jSurface2, in: Capsule())
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in text = strings.first ?? "" }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.circle)
                .tint(Color.jCyanText)
            }

            status.frame(minHeight: 40, alignment: .topLeading)

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle(height: 50))
                Button(action: add) {
                    Text("Jot").font(.onest(16, .bold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(height: 50))
                .disabled(checking || verdict.link == nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.jBg)
        .onAppear { focused = true }
        // A short think after each paste or edit, then the verdict.
        .task(id: text) {
            guard !text.isEmpty else { checking = false; return }
            checking = true
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { withAnimation(.snappy(duration: 0.2)) { checking = false } }
        }
    }

    @ViewBuilder private var status: some View {
        if checking {
            HStack(spacing: 10) {
                OrbView(kind: .searching, size: 24)
                Text("Checking the link…").font(.onest(14.5)).foregroundStyle(Color.jMute)
            }
        } else {
            switch verdict {
            case .empty:
                Text("Instagram, TikTok, YouTube, X, Vimeo or Loom. Jot only opens what anyone can see without signing in.")
                    .font(.onest(13.5)).foregroundStyle(Color.jMute)
            case .ok(_, let what):
                Label { Text("\(what). Jot can open this.").foregroundStyle(Color.jInk) } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.jCyanText)
                }
                .font(.onest(14.5, .semibold))
            case .no(let why):
                Label { Text(why).foregroundStyle(Color.jInk) } icon: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.jBad)
                }
                .font(.onest(14.5))
            }
        }
    }

    private func add() {
        guard !checking, let url = verdict.link else { return }
        store.add(link: url.absoluteString)
        dismiss()
    }
}
