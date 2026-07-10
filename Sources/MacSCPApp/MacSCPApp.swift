import SwiftUI

@main
struct MacSCPApp: App {
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
            ContentView()
        }
    }
}
