import Foundation
import macSCPCore

/// `windows.json` — what the last quit left on screen (Detachable Tabs
/// plan, Task 5).
///
/// A stateless struct over a directory, exactly like `AuditLogStore`: the
/// file is the state, and every call reads or writes it whole. The list is
/// in the order the windows CLOSED, because that is the order the
/// descriptions arrive in — one append per `NSWindow.willCloseNotification`
/// — and quitting closes windows, so the order is close to the order they
/// were opened in.
///
/// **The directory is resolved, not spelled.** `defaultDirectory` defers to
/// `SessionStore.defaultDirectory`, the one lookup that honours the
/// `MACSCP_STORAGE_DIRECTORY` override, so this file lands beside
/// `sessions-v2.json` and `settings.json` rather than beside a second idea
/// of where the app's data lives.
///
/// **Not a secret store, and structurally unable to become one.** What it
/// writes is `[WindowSeed]`, whose stored properties are identifiers and
/// booleans — see that type's doc comment and the type check in
/// `WindowRestorationWiringGuardTests`. Secrets live in the Keychain
/// (`SecretStore`) and JSON stores never contain them; this is one more
/// JSON store.
///
/// **Both mutating entry points take the setting**, rather than being
/// called behind an `if` at each site, so "the setting is off" is one
/// decision (`WindowRestorationPlan`) expressed once. With it off an
/// existing file is left exactly as found: not written to, not read, not
/// cleared. Turning the setting on later must not resurrect the windows of
/// whenever it was last on — and what prevents that is the read side,
/// which CONSUMES the file it restores from.
struct WindowRestorationStore: Sendable {
    /// The same directory every other JSON store uses — see the type's doc
    /// comment for why this defers rather than spelling a path.
    static var defaultDirectory: URL { SessionStore.defaultDirectory }

    let directory: URL

    var fileURL: URL {
        directory.appendingPathComponent("windows.json")
    }

    init(directory: URL) {
        self.directory = directory
    }

    /// Adds one closing window's description to the end of the file.
    ///
    /// A no-op — including creating the file — when the setting is off.
    /// A failed read of an existing file is treated as an empty list
    /// rather than an error: losing a description is a smaller harm than
    /// refusing to record the one this window has, and the launch that
    /// reads it already tolerates junk.
    func append(_ seed: WindowSeed, whenEnabled flag: Bool) {
        guard WindowRestorationPlan.shouldWrite(flag: flag) else { return }
        write(read() + [seed])
    }

    /// Every description in the file, oldest close first. Empty when the
    /// file is missing, unreadable, or not the JSON this version writes —
    /// a launch must never fail because of what is in here.
    func read() -> [WindowSeed] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([WindowSeed].self, from: data)) ?? []
    }

    /// What this launch should restore, taking the file with it.
    ///
    /// The clear is the whole reason this is one call rather than a read
    /// and a later delete: a seed file is consumed ONCE. Without that, a
    /// launch that crashed before any window closed would reopen the
    /// windows of the launch before it, and so would the one after that,
    /// forever. With the setting off nothing is read and nothing is
    /// cleared.
    func readAndClear(whenEnabled flag: Bool) -> [WindowSeed] {
        guard WindowRestorationPlan.shouldRead(flag: flag) else { return [] }
        let seeds = read()
        clear()
        return seeds
    }

    /// Removes the file. Missing is success — there is nothing to consume.
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func write(_ seeds: [WindowSeed]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(seeds) else { return }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
