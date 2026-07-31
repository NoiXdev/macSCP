import AppKit
import Foundation
import Observation
import macSCPCore

/// Shared alert copy for `UpdateCheckResult` (M11b/T2 spec §4) — one source
/// for both `ContentView`'s in-window `.alert` and `UpdateCheckModel`'s
/// `NSAlert` fallback below, so the two presentations can never drift apart
/// (M11b final review, Finding I2).
enum UpdateAlertContent {
    static func title(for result: UpdateCheckResult?) -> String {
        switch result {
        case .updateAvailable:
            return L10n.string("update.available.title", "Update Available")
        case .upToDate:
            return L10n.string("update.upToDate.title", "No Update Available")
        case .unknownLocalVersion:
            return L10n.string("update.unknownVersion.title", "Version Unknown")
        case .failed:
            return L10n.string("update.error.title", "Update Check Failed")
        case nil:
            return ""
        }
    }

    /// The `.updateAvailable` wording is spec-mandated verbatim (spec §4):
    /// "Version %@ is available (installed: %@)". `.unknownLocalVersion`
    /// gets its own honest message and no link (spec §4) — never an update
    /// claim built on a version that couldn't be read. Each
    /// `UpdateCheckError` case gets its own message.
    static func message(for result: UpdateCheckResult?) -> String {
        switch result {
        case .updateAvailable(let latest, let current, _):
            return String(
                format: L10n.string(
                    "update.available.message %@ %@", "Version %@ is available (installed: %@)"),
                latest.description, current.description)
        case .upToDate(let current):
            return String(
                format: L10n.string("update.upToDate.message %@", "macSCP %@ is the latest version."),
                current.description)
        case .unknownLocalVersion:
            return L10n.string(
                "update.unknownVersion.message",
                "This build's version could not be determined, so no update check could be performed.")
        case .failed(let error):
            switch error {
            case .offline:
                return L10n.string(
                    "update.error.offline",
                    "Could not reach GitHub. Check your internet connection and try again.")
            case .httpStatus(let code):
                return String(
                    format: L10n.string(
                        "update.error.httpStatus %lld", "GitHub returned an unexpected error (HTTP %lld)."),
                    code)
            case .rateLimited:
                return L10n.string(
                    "update.error.rateLimited", "Too many requests to GitHub right now. Try again later.")
            case .malformedResponse:
                return L10n.string(
                    "update.error.malformedResponse", "The response from GitHub could not be understood.")
            }
        case nil:
            return ""
        }
    }
}

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
    /// showing. A MANUAL check (menu item) always sets this — but only when
    /// some `ContentView` is actually mounted to consume it via `hasPresentationTarget`;
    /// see `check` below. An AUTOMATIC check (startup) only sets this for
    /// `.updateAvailable` — every other outcome stays completely silent
    /// (spec §3).
    var presentedResult: UpdateCheckResult?

    /// Whether a `ContentView` is currently in the view hierarchy to show
    /// `presentedResult` via its `.alert`. Toggled by `ContentView` itself
    /// (`.onAppear`/`.onDisappear`) — NOT tied to window key-ness, just
    /// existence: the menu item is app-global and can fire (or a check
    /// started earlier can complete) while every window is closed (M11b
    /// final review, Finding I2). `false` at init since no view has
    /// appeared yet.
    var hasPresentationTarget = false

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
    ///
    /// Whether a window exists is re-checked here, right after the `await`
    /// (not just once at entry) — with no suspension point between that
    /// check and using its result, it can't go stale before use (M11b final
    /// review, Finding I2): a manual check with no mounted view falls back
    /// to a plain `NSAlert` instead of writing into `presentedResult` for
    /// nobody to read, which would otherwise resurface as a stale, unrequested
    /// dialog the next time a window opens.
    func check(manual: Bool, settingsStore: SettingsStore) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let fetcher = GitHubReleaseFetcher(userAgentVersion: bundleVersion ?? "unknown")
        let checker = UpdateChecker(fetcher: fetcher, currentVersion: bundleVersion)
        let result = await checker.check()

        settingsStore.lastUpdateCheck = Date()

        let isUpdateAvailable: Bool
        if case .updateAvailable = result {
            isUpdateAvailable = true
        } else {
            isUpdateAvailable = false
        }
        guard manual || isUpdateAvailable else { return }

        if hasPresentationTarget {
            presentedResult = result
        } else if manual {
            presentFallbackAlert(for: result)
        }
        // Automatic + no mounted view: silently dropped — consistent with
        // the automatic check's existing silence for every non-"update
        // available" outcome, and it'll be re-evaluated at the next due
        // date anyway (spec §3).
    }

    /// Manual check, no `ContentView` around to show the in-window `.alert`
    /// (every window closed): shows a plain app-modal `NSAlert` instead, so
    /// "a manual check always shows a result" holds even then (M11b final
    /// review, Finding I2). Copy comes from the same `UpdateAlertContent`
    /// `ContentView`'s `.alert` uses, so the two can't diverge.
    private func presentFallbackAlert(for result: UpdateCheckResult) {
        let alert = NSAlert()
        alert.messageText = UpdateAlertContent.title(for: result)
        alert.informativeText = UpdateAlertContent.message(for: result)

        if case .updateAvailable(_, _, let url) = result {
            alert.addButton(withTitle: L10n.string("update.openReleasePage", "Open Release Page"))
            alert.addButton(withTitle: L10n.string("update.later", "Later"))
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(url)
            }
        } else {
            alert.addButton(withTitle: L10n.string("common.ok", "OK"))
            alert.runModal()
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
