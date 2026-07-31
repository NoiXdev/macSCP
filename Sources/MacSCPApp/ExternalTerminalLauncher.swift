import AppKit
import Foundation
import macSCPCore

/// Opens an SSH session in an external terminal app (M11d).
///
/// The connection is never automated through AppleScript or an app-specific
/// bridge — that would need a new entitlement. Instead this writes a
/// disposable `.command` script (built by the pure, security-reviewed
/// `SSHCommandBuilder`) into its own 0700 temp file and hands it to
/// `NSWorkspace`, which opens it with the chosen terminal app exactly as if
/// the user had double-clicked it in Finder. The script removes itself
/// before `exec`ing into `ssh` (see `SSHCommandBuilder.scriptContents`), so
/// nothing lingers after launch except while the app is still starting up.
@MainActor
enum ExternalTerminalLauncher {
    /// Typed failures — no case here ever falls back to a different app or
    /// to the built-in terminal; the caller surfaces the message as-is.
    enum LaunchError: Error, Equatable {
        /// The chosen app (name for `.terminalApp`/`.iTerm`, path for
        /// `.custom`) could not be resolved to a launchable application.
        case applicationNotFound(String)
        /// `target == .custom` but no app has been chosen yet (`customPath`
        /// is nil/empty) — distinct from `.applicationNotFound`, which
        /// always names a concrete (but unusable) app/path (review finding
        /// I-1, M11d final review): without this case the empty path fell
        /// through to `.applicationNotFound("")` and the alert named
        /// nothing ("Couldn't find “”.").
        case noCustomAppChosen
        /// The disposable script could not be written; `String` is the
        /// underlying reason (e.g. an `Error`'s description).
        case scriptWriteFailed(String)
        /// `NSWorkspace` accepted the launch request but it failed
        /// asynchronously (e.g. a damaged/quarantined bundle); `String` is
        /// the underlying reason (review finding I-2, M11d final review).
        case launchFailed(String)
    }

    private static let terminalAppBundleID = "com.apple.Terminal"
    private static let iTermBundleID = "com.googlecode.iterm2"

    /// Root temp directory for disposable launch scripts — its own
    /// subfolder, mirroring `EditSessionManager`'s `macscp-edit` (M5e/M6a):
    /// swept as a whole at app launch (`sweepOrphanedTempDirectories`), and
    /// each script also removes itself once `ssh` starts (`scriptContents`).
    /// `nonisolated`: a default-parameter expression is evaluated outside
    /// the enclosing type's actor context, so a `@MainActor`-isolated
    /// property can't serve as one — this touches no actor-isolated state
    /// anyway (just `FileManager`/`String`).
    nonisolated static var defaultRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-terminal", isDirectory: true)
    }

    /// Writes `config`'s script to a fresh `<root>/<uuid>.command` (0700)
    /// and opens it with the app resolved from `target`/`customPath`.
    ///
    /// `target == .builtIn` is a no-op: the built-in panel is toggled by the
    /// caller directly, never routed through this launcher. The case only
    /// exists here for `TerminalTarget`'s exhaustiveness — the UI never
    /// calls this with `.builtIn` (see `ContentView.requestExternalTerminal`).
    /// `async throws` (not the `completionHandler: nil` fire-and-forget this
    /// used to be, review finding I-2): `NSWorkspace`'s launch can fail
    /// AFTER being accepted — a damaged or quarantined bundle, for
    /// instance — and that failure must reach the caller the same way every
    /// other `LaunchError` does, not vanish silently while leaving the
    /// disposable script behind.
    static func open(
        config: SSHConnectionConfig, target: TerminalTarget, customPath: String?,
        root: URL = defaultRoot
    ) async throws {
        guard target != .builtIn else { return }
        let appURL = try resolveApplication(target: target, customPath: customPath)
        let scriptURL = try writeScript(for: config, root: root)
        do {
            _ = try await NSWorkspace.shared.open(
                [scriptURL], withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration())
        } catch {
            throw LaunchError.launchFailed(error.localizedDescription)
        }
    }

    /// Removes the entire `macscp-terminal` temp tree at app launch, mirror
    /// image of `EditSessionManager.sweepOrphanedTempDirectories`: a
    /// hard-killed previous run may have left a script behind (the normal
    /// case is self-deletion right after `ssh` starts, see
    /// `SSHCommandBuilder.scriptContents`). No script can be "in use" at
    /// launch time (scripts are disposable and single-shot), so sweeping the
    /// whole tree is safe. Idempotent; a missing tree is a no-op.
    static func sweepOrphanedTempDirectories(root: URL = defaultRoot) {
        try? FileManager.default.removeItem(at: root)
    }

    /// Resolves `target`/`customPath` to an application URL, or throws
    /// `.applicationNotFound` — never a fallback to a different app.
    private static func resolveApplication(target: TerminalTarget, customPath: String?) throws -> URL {
        switch target {
        case .builtIn:
            // Unreachable: `open(...)` returns before calling this for
            // `.builtIn`. Kept for `TerminalTarget`'s exhaustiveness only.
            throw LaunchError.applicationNotFound("")
        case .terminalApp:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalAppBundleID)
            else { throw LaunchError.applicationNotFound("Terminal") }
            return url
        case .iTerm:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: iTermBundleID)
            else { throw LaunchError.applicationNotFound("iTerm") }
            return url
        case .custom:
            guard let customPath, !customPath.isEmpty else {
                throw LaunchError.noCustomAppChosen
            }
            guard isValidCustomApp(atPath: customPath) else {
                throw LaunchError.applicationNotFound(customPath)
            }
            return URL(fileURLWithPath: customPath)
        }
    }

    /// Whether `path` points at a real, launchable application bundle — the
    /// same check `resolveApplication(target: .custom, ...)` performs right
    /// before launching. Exposed (not `private`) so `ContentView
    /// .requestExternalTerminal` can decide, ahead of ever calling `open`,
    /// whether a configured custom app is usable as the `.builtIn` fallback
    /// (review finding, M11d fix round 1) instead of silently substituting
    /// Terminal.app for a validly configured custom app.
    static func isValidCustomApp(atPath path: String?) -> Bool {
        guard let path, !path.isEmpty,
            FileManager.default.fileExists(atPath: path),
            Bundle(path: path)?.bundleIdentifier != nil
        else { return false }
        return true
    }

    /// Writes `SSHCommandBuilder.scriptContents(for:)` to a fresh UUID-named
    /// `.command` file under `root`, created with 0700 permissions from the
    /// start (`FileManager.createFile(atPath:contents:attributes:)`) —
    /// NEVER create-then-`chmod`, which would briefly leave the script
    /// (containing the target host/username/key path) world-readable.
    private static func writeScript(for config: SSHConnectionConfig, root: URL) throws -> URL {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw LaunchError.scriptWriteFailed(error.localizedDescription)
        }
        let scriptURL = root.appendingPathComponent("\(UUID().uuidString).command")
        guard let data = SSHCommandBuilder.scriptContents(for: config).data(using: .utf8) else {
            throw LaunchError.scriptWriteFailed(scriptURL.lastPathComponent)
        }
        let created = FileManager.default.createFile(
            atPath: scriptURL.path(percentEncoded: false), contents: data,
            attributes: [.posixPermissions: 0o700])
        guard created else {
            throw LaunchError.scriptWriteFailed(scriptURL.lastPathComponent)
        }
        return scriptURL
    }
}
