import SwiftUI

/// Jot's colours and type (design/DESIGN.md), shared by the app and the share extension.
extension Color {
    static let jBg = Color(light: 0xF4F7F9, dark: 0x05090D)
    static let jSurface = Color(light: 0xFFFFFF, dark: 0x0E161D)
    static let jSurface2 = Color(light: 0xE9EFF3, dark: 0x16212A)
    static let jInk = Color(light: 0x0A1620, dark: 0xE8F4F8)
    static let jMute = Color(light: 0x5E6F7C, dark: 0x7F909C)
    static let jLine = Color(light: 0xDCE4EA, dark: 0x1C2832)
    static let jCyan = Color(hex: 0x18CFFF)
    static let jCyanText = Color(light: 0x007CA6, dark: 0x18CFFF)
    static let jOnCyan = Color(hex: 0x0A1620)
    static let jBad = Color(light: 0xC2410C, dark: 0xFF8A5B)

    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    init(light: UInt32, dark: UInt32) {
        #if os(iOS)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(Color(hex: dark)) : UIColor(Color(hex: light)) })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(Color(hex: dark)) : NSColor(Color(hex: light))
        })
        #endif
    }
}

extension Font {
    static func onest(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Onest", size: size).weight(weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Martian Mono", size: size).weight(weight)
    }
}

/// Side margins. Glass, buttons and fields sit at `edge`; text sits a little further in at `text`, roughly
/// where the words inside those containers start, so text never lines up flush with a container's edge.
enum Inset {
    static let edge: CGFloat = 16
    static let text: CGFloat = 26
    /// Widest a column of reading text gets (sideways on a phone the screen is ~870 pt; lines that long are hard to follow).
    static let reading: CGFloat = 680
}
