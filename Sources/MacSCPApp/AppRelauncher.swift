import AppKit

/// Relaunches the running app (M11p): used after a language change, which
/// only takes effect on a fresh launch (the bundle's localized tables cache
/// after first use). Spawns a detached shell that waits for this process to
/// exit, then reopens the .app, and terminates immediately. A deliberate
/// user action — no `deinit` cleanup needed, same as a normal quit.
@MainActor
enum AppRelauncher {
    static func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 1; open \"\(bundlePath)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
