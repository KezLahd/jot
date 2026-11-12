import SwiftUI

/// System, Light or Dark, chosen in Settings. Kept in the app group so the share sheet follows it too.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance"
    static let defaults = UserDefaults(suiteName: "group.com.kezlahd.jot") ?? .standard
    static var current: Appearance { Appearance(rawValue: defaults.string(forKey: key) ?? "") ?? .system }

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    #if os(iOS)
    var style: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
    #else
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
    #endif
}
