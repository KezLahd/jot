import SwiftUI

/// The thinking orbs (ThinkingOrbsKit, vendored): every wait state uses one.
/// Listening = transcribing, searching = fetching. Drawn as vectors, so they're crisp at any size,
/// and they follow light and dark mode on their own.
struct OrbView: View {
    enum Kind { case listening, searching }
    var kind: Kind
    var size: CGFloat

    var body: some View {
        // The 20 px preset has fewer, bolder dots, which reads better in list rows.
        ThinkingOrb(state: kind == .listening ? .listening : .searching,
                    size: size < 44 ? .px20 : .px64,
                    displaySize: size)
            .accessibilityLabel(kind == .listening ? "Listening" : "Fetching")
    }
}
