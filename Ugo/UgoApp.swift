import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct UgoApp: App {
    @State private var store = NotesStore()
    @State private var appState = AppState()

    init() {
        #if os(macOS)
        UgoApp.handOffToRunningCopy()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(appState)
        }
        .commands {
            AppCommands(appState: appState, store: store)
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(store)
                .environment(appState)
        }
        #endif
    }
}

#if os(macOS)
extension UgoApp {
    /// macOS treats every bundle path as its own app, so a Ugo launched from a
    /// second location (a build under the repo, a stale launcher entry) would
    /// open beside the one already running and both would share the database.
    /// Hand the user over to the running copy and quit instead.
    static func handOffToRunningCopy() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me && !$0.isTerminated }
        guard let other = running.first else { return }

        other.activate(options: [.activateAllWindows])
        if let url = other.bundleURL {
            // Opening the running bundle again is what the Dock does: Launch
            // Services brings it to the front regardless of who is active.
            let sent = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                sent.signal()
            }
            _ = sent.wait(timeout: .now() + 2)
        }
        exit(0)
    }
}
#endif
