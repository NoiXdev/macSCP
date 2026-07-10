import SwiftUI
import macSCPCore

@main
struct MacSCPApp: App {
    /// Single instance for the whole app — passed to `ContentView` and the
    /// `Settings` scene below (M5c/T3: no singleton, per the v2 multi-window
    /// rule).
    @State private var settingsStore = SettingsStore(directory: SettingsStore.defaultDirectory)

    init() {
        // Ohne App-Bundle (Start via `swift run`) läuft der Prozess als
        // Accessory — erst die Regular-Policy bringt Fenster und Dock-Icon.
        // Echtes .app-Bundle kommt in M6.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        // Die Mindestgröße hängt vom Verbindungszustand ab (kompaktes
        // Formular vs. Browser) — sie lebt deshalb konditional in
        // `ContentView` statt hier global (M5c/T0).
        WindowGroup("macSCP") {
            ContentView(settingsStore: settingsStore)
        }

        // Opened via Cmd-, or the app menu's "Settings…" item (M5c/T3).
        Settings {
            SettingsView(store: settingsStore)
        }
    }
}
