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
        WindowGroup("macSCP") {
            Text("macSCP — M2 in Arbeit")
                .padding()
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}
