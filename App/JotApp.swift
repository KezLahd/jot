import JotCore
import SwiftUI

@main
struct JotApp: App {
    @State private var store = Store()
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    #if os(macOS)
    @State private var worker = Worker()
    #endif

    init() {
        Theme.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(store)
                .modifier(AppearanceRoot())
                .onAppear {
                    store.start()
                    #if os(macOS)
                    worker.start(store: store)
                    #endif
                }
                #if os(macOS)
                .frame(minWidth: 380, idealWidth: 420, minHeight: 560, idealHeight: 760)
                #endif
        }
        #if os(macOS)
        .windowResizability(.contentMinSize)
        #endif

        #if os(macOS)
        MenuBarExtra {
            WorkerMenu().environment(store).environment(worker)
        } label: {
            Image(nsImage: Theme.menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            MacSettings().environment(store).environment(worker)
        }
        #endif
    }
}
