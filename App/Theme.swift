import CoreText
import SwiftUI

/// Jot's look (design/DESIGN.md): Cyan & ink, Onest for text, Martian Mono for timestamps.
enum Theme {
    static let iCloudContainer = "iCloud.com.kezlahd.jot"

    static func registerFonts() {
        for name in ["Onest", "MartianMono"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

/// A rounded "card" row like the mockups.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.jSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Cyan capsule for the one thing to act on.
struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 40
    func makeBody(configuration: Configuration) -> some View {
        Filled(configuration: configuration, height: height)
    }

    private struct Filled: View {
        let configuration: Configuration
        let height: CGFloat
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.onest(15, .semibold))
                .foregroundStyle(enabled ? Color.jOnCyan : Color.jMute)
                .padding(.horizontal, 16)
                .frame(height: height)
                .background(enabled ? Color.jCyan : Color.jSurface2, in: Capsule())
                .opacity(configuration.isPressed ? 0.75 : 1)
                .animation(.snappy(duration: 0.2), value: enabled)
        }
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 40
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.onest(15, .semibold))
            .foregroundStyle(Color.jInk)
            .padding(.horizontal, 15)
            .frame(height: height)
            .background(Color.jSurface2, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension Date {
    /// "Today", "Yesterday", or "8 Nov".
    var dayLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today" }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        return formatted(.dateTime.day().month(.abbreviated))
    }
}

#if os(macOS)
import AppKit
extension Theme {
    /// The quote mark at menu-bar size. A MenuBarExtra label ignores SwiftUI frames, so the image itself must be small.
    static let menuBarIcon: NSImage = {
        guard let source = NSImage(named: "QuoteMark"), source.size.height > 0 else { return NSImage() }
        let height: CGFloat = 15
        let size = NSSize(width: (height * source.size.width / source.size.height).rounded(), height: height)
        let image = NSImage(size: size, flipped: false) { rect in source.draw(in: rect); return true }
        image.isTemplate = true
        return image
    }()
}
#endif
