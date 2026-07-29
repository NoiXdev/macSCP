import Foundation
import Observation
import macSCPCore

/// App-global update-check state and control (M11b/T2).
///
/// Deliberately NOT part of `SessionTab`/`TabsViewModel` or any per-window
/// state: comparing the running bundle against the latest GitHub release
/// has nothing to do with which window or tab is active — it's the same
/// question regardless. It's held as a single `@Observable` instance on
/// `MacSCPApp` (mirrors `TabCommands`'s shape: a small app-level bridge, not
/// a singleton — `MacSCPApp` owns and injects it, same as `settingsStore`).
///
/// `SettingsStore` isn't captured at `init` time on purpose: `check` and
/// `checkAutomaticallyIfDue` take it as a parameter instead, so this class
/// carries no dependency-construction-order requirements and can be a plain
/// `@State private var updateModel = UpdateCheckModel()` in `MacSCPApp`.
@MainActor
@Observable
final class UpdateCheckModel {
    /// True while a check (automatic or manual) is in flight. The menu
    /// item's multi-click guard reads this (spec §4): "already checking"
    /// disables the entry instead of starting a second overlapping check.
    private(set) var isChecking = false

    /// The result to present as an alert, or `nil` when no dialog is
    /// showing. A MANUAL check (menu item) always sets this. An AUTOMATIC
    /// check (startup) only sets this for `.updateAvailable` — every other
    /// outcome stays completely silent (spec §3).
    var presentedResult: UpdateCheckResult?

    /// Runs one check attempt. Guarded by `isChecking` so an automatic and
    /// a manual check (or two manual clicks) never overlap: the guard-and-set
    /// happens synchronously before the first `await`, so it's race-free
    /// even if called from two concurrently-started `Task`s on the main
    /// actor.
    ///
    /// The local version comes from `Bundle.main` here (App layer) — Core's
    /// `UpdateChecker`/`GitHubReleaseFetcher` never touch `Bundle` (spec §2,
    /// Global Constraints: "Core bleibt bundle-frei"). A missing/unparsable
    /// version flows through unchanged to `.unknownLocalVersion` — no
    /// special-casing here (spec §3/§6).
    ///
    /// `settingsStore.lastUpdateCheck` is written after EVERY attempt,
    /// success or failure (Global Constraints), so a dead network doesn't
    /// retry on every subsequent launch within the 24h window.
    func check(manual: Bool, settingsStore: SettingsStore) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let fetcher = GitHubReleaseFetcher(userAgentVersion: bundleVersion ?? "unknown")
        let checker = UpdateChecker(fetcher: fetcher, currentVersion: bundleVersion)
        let result = await checker.check()

        settingsStore.lastUpdateCheck = Date()

        if manual {
            presentedResult = result
        } else if case .updateAvailable = result {
            presentedResult = result
        }
    }

    /// Startup automatic check (spec §3): fires at most once a day, never
    /// blocks (the actual check runs in a detached-from-caller `Task`), and
    /// silently no-ops when disabled or not yet due per `UpdateSchedule`.
    func checkAutomaticallyIfDue(settingsStore: SettingsStore, now: Date = Date()) {
        guard
            UpdateSchedule.shouldCheck(
                now: now, lastCheck: settingsStore.lastUpdateCheck,
                enabled: settingsStore.updateCheckEnabled)
        else { return }
        Task {
            await check(manual: false, settingsStore: settingsStore)
        }
    }
}
