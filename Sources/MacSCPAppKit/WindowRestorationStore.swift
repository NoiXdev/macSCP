import Foundation
import macSCPCore

/// `windows.json` — what the last quit left on screen (Detachable Tabs
/// plan, Task 5).
///
/// A stateless struct over a directory, exactly like `AuditLogStore`: the
/// file is the state, and every call reads or writes it whole. The list is
/// every window that was OPEN at the quit that wrote it, in the order
/// those windows appeared (`TabRegistry.describeAllWindows()`), written
/// once from `AppDelegate.applicationWillTerminate`.
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
/// **Both entry points take the setting**, rather than being called behind
/// an `if` at each site, so "the setting is off" is one decision
/// (`WindowRestorationPlan`) expressed once. With it off, both of them
/// DELETE the file: a seed file describes one quit, and a stale one has no
/// owner. Consumed at the launch that reads it, discarded by any launch or
/// quit that is not restoring — never kept.
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

    /// Replaces the file with the windows open at this moment.
    ///
    /// One write, at one moment — `applicationWillTerminate` — and never
    /// an append. The first version of this appended on each window's
    /// `willClose`, which described exactly the wrong set: ⌘Q closes no
    /// windows (measured in this repository for the parked-move sweep, and
    /// recorded in `AppDelegate.sweepUnclaimedMoves()`'s doc comment), so
    /// the windows actually on screen at quit were never described, while
    /// every window the user had deliberately closed during the session
    /// accumulated in the file.
    ///
    /// With the setting off the file is DELETED rather than left alone. A
    /// seed file describes one quit; a stale one has no owner and no
    /// meaning, and leaving it would mean a later switch-on restored the
    /// windows of whenever the setting was last on. Consumed or discarded,
    /// never kept — the launch side (`consumeAtLaunch(whenEnabled:)`)
    /// states the same rule from the other end.
    func replace(_ seeds: [WindowSeed], whenEnabled flag: Bool) {
        guard WindowRestorationPlan.shouldWrite(flag: flag) else {
            clear()
            return
        }
        write(seeds)
    }

    /// Every description in the file, oldest window first. Empty when the
    /// file is missing, unreadable, or not the JSON this version writes —
    /// a launch must never fail because of what is in here.
    func read() -> [WindowSeed] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([WindowSeed].self, from: data)) ?? []
    }

    /// What this launch should restore. **The file is always consumed.**
    ///
    /// Read then deleted when the setting is on; deleted unread when it is
    /// off. Both directions matter and they are the same rule seen twice:
    ///
    /// - Without the delete-after-read, a launch that crashed before its
    ///   quit sweep ran would reopen its predecessor's windows, and so
    ///   would the launch after that, forever.
    /// - Without the delete-when-off, a run with the setting off would
    ///   leave the previous run's file untouched while writing nothing of
    ///   its own, and the next launch with the setting on would restore a
    ///   generation of windows that is two quits old.
    ///
    /// So no launch can ever see two generations mixed, and no file
    /// outlives the launch that found it.
    func consumeAtLaunch(whenEnabled flag: Bool) -> [WindowSeed] {
        let seeds = WindowRestorationPlan.shouldRead(flag: flag) ? read() : []
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
