import SwiftUI
#if os(iOS)
import UserNotifications
#endif

extension Appearance {
    /// Sets the whole app's look. On iOS the window's style, so sheets and the record screen follow it as well.
    @MainActor func apply() {
        #if os(iOS)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.windows.forEach { $0.overrideUserInterfaceStyle = style }
        }
        #else
        NSApp.appearance = nsAppearance
        #endif
    }
}

/// The app follows the choice through the window's style (NSApp's appearance on the Mac), not SwiftUI's
/// preferredColorScheme: that one sticks on dark when you go back to System. Sheets follow the window.
struct AppearanceRoot: ViewModifier {
    @AppStorage(Appearance.key, store: Appearance.defaults) private var appearance = Appearance.system

    func body(content: Content) -> some View {
        content
            .onChange(of: appearance) { _, mode in mode.apply() }
            .task { appearance.apply() }
    }
}

#if os(iOS)
/// The three dots on home: one page laid out like the Settings app, changed in place.
struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(Appearance.key, store: Appearance.defaults) private var appearance = Appearance.system
    @State private var alerts: UNAuthorizationStatus = .notDetermined

    var body: some View {
        NavigationStack {
            List {
                Section("Appearance") {
                    HStack(spacing: 0) {
                        ForEach(Appearance.allCases) { mode in
                            ModeTile(mode: mode, selected: appearance == mode) { appearance = mode }
                        }
                    }
                    .padding(.vertical, 10)
                    .sensoryFeedback(.selection, trigger: appearance)
                }

                Section {
                    NavigationLink {
                        DeletedView(pushed: true)
                    } label: {
                        LabeledContent("Recently deleted") {
                            Text(store.deleted.isEmpty ? "" : "\(store.deleted.count)").font(.mono(14))
                        }
                    }
                    LabeledContent("Saved in", value: store.usingICloud ? "iCloud" : "This iPhone")
                } header: {
                    Text("Library")
                } footer: {
                    Text(store.usingICloud
                         ? "Transcripts sync to your Mac and other devices through iCloud."
                         : "Sign in to iCloud on this iPhone to sync transcripts with your Mac.")
                }

                Section {
                    whisper
                    NavigationLink {
                        CloudSettingsView(pushed: true)
                    } label: {
                        LabeledContent("Cloud fetch", value: store.cloudReady ? "On" : "Off")
                    }
                } header: {
                    Text("Transcribing")
                } footer: {
                    Text("Cloud fetch transcribes links on GitHub while your Mac is asleep. It only sees what a logged-out visitor sees.")
                }

                Section {
                    Button {
                        if alerts == .notDetermined {
                            Task {
                                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                                await refreshAlerts()
                            }
                        } else if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        LabeledContent("Notifications") {
                            HStack(spacing: 6) {
                                Text(alertsText)
                                Image(systemName: "arrow.up.forward").font(.footnote.weight(.semibold))
                            }
                        }
                    }
                    .tint(Color.jInk)
                } footer: {
                    Text("Jot tells you when a transcript is ready.")
                }

                Section {
                } footer: {
                    Text("Jot \(version)")
                        .font(.mono(12))
                        .frame(maxWidth: .infinity)
                }
            }
            .font(.onest(16))
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .scrollContentBackground(.hidden)
            .background(Color.jBg)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(Color.jCyanText)
        .task { await refreshAlerts() }
    }

    @ViewBuilder private var whisper: some View {
        switch store.model {
        case .ready: LabeledContent("Whisper", value: "On this iPhone")
        case .downloading(let line): LabeledContent("Whisper", value: line)
        case .missing: LabeledContent("Whisper", value: "Not downloaded")
        case .failed:
            Button { store.downloadModelIfNeeded() } label: {
                LabeledContent("Whisper") { Text("Retry download") }
            }
            .tint(Color.jInk)
        }
    }

    private func refreshAlerts() async {
        alerts = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private var alertsText: String {
        switch alerts {
        case .authorized, .provisional, .ephemeral: "On"
        case .denied: "Off"
        default: "Turn on"
        }
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

/// System, Light or Dark as a little Jot home screen in that look.
private struct ModeTile: View {
    let mode: Appearance
    let selected: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            phone
                .padding(3)
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(selected ? Color.jCyan : .clear, lineWidth: 2.5)
                }
            Text(mode.title)
                .font(.onest(13, selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.jInk : Color.jMute)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundStyle(selected ? Color.jCyanText : Color.jMute.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { action() }
    }

    private var phone: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Group {
            switch mode {
            case .light: screen(dark: false)
            case .dark: screen(dark: true)
            case .system:
                screen(dark: false).overlay(alignment: .trailing) {
                    screen(dark: true).frame(width: 29, alignment: .trailing).clipped()
                }
            }
        }
        .frame(width: 58, height: 98)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.jInk.opacity(0.15)) }
    }

    /// Jot's home in miniature: the cyan j, then rows of words under hairlines.
    private func screen(dark: Bool) -> some View {
        let bg = Color(hex: dark ? 0x05090D : 0xF4F7F9)
        let ink = Color(hex: dark ? 0xE8F4F8 : 0x0A1620)
        let mute = Color(hex: dark ? 0x7F909C : 0x5E6F7C)
        let line = Color(hex: dark ? 0x1C2832 : 0xDCE4EA)
        return ZStack(alignment: .topLeading) {
            bg
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 2) {
                    Capsule().fill(Color.jCyan).frame(width: 3, height: 8)
                    Capsule().fill(ink).frame(width: 9, height: 5)
                }
                .padding(.bottom, 4)
                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 3) {
                        Capsule().fill(ink).frame(width: 30, height: 4)
                        Capsule().fill(mute.opacity(0.6)).frame(width: 40, height: 3)
                        Rectangle().fill(line).frame(height: 0.5).padding(.top, 2)
                    }
                }
            }
            .padding(.horizontal, 8).padding(.top, 12)
        }
        .frame(width: 58, height: 98)
    }
}
#endif
