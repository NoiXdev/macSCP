import Foundation

/// Where the `macscp-cli` shortcut in the user's `bin` directory stands
/// relative to the running app's own copy of the tool.
///
/// The distinction that matters is `stale`: `macscp-cli` ships inside the app
/// bundle, so the shortcut points INTO a specific `.app`. Move that app,
/// replace it with a fresh download, or delete the copy the shortcut was made
/// from, and the shortcut keeps pointing at the old location — silently
/// running an outdated build, or nothing at all. Comparing the resolved
/// destination against the running app's own tool is the only way to tell.
public enum CLIInstallState: Equatable, Sendable {
    /// Nothing at the shortcut path.
    case notInstalled
    /// A symlink resolving to the running app's own `macscp-cli`.
    case installed
    /// A symlink resolving to something else. `target` is the absolute path
    /// it points at (which may no longer exist), so the UI can name it — and
    /// is `nil` in the one case where we genuinely do not know: a symlink
    /// whose destination cannot be read at all. The UI must then say nothing
    /// about a target rather than invent one.
    case stale(target: String?)
    /// Something that is NOT a symlink sits at the shortcut path — a regular
    /// file, or a directory. Installing would destroy it, so it never
    /// happens; the user is told and decides.
    case occupied
    /// The app is running TRANSLOCATED (see `isTranslocated`). Linking now
    /// would produce a shortcut into a disk image or a randomised read-only
    /// mount that disappears when the app quits — green in the UI, dead the
    /// moment it matters. Nothing is installed; the user is told to move
    /// macSCP to Applications and open it from there.
    case translocated
}

public enum CLIInstallError: Error, Equatable, Sendable {
    /// `install()` refused because `state()` was `.occupied`. The associated
    /// value is the absolute shortcut path, for the message.
    case pathOccupied(String)
    /// `install()` refused because the app is running translocated.
    case appIsTranslocated
}

/// Creates and inspects the `macscp-cli` shortcut in a user-writable `bin`
/// directory, following the `ManagedKeyStore`/`KnownHostsStore` pattern:
/// stateless, injected paths, no global state, testable against a temporary
/// directory.
///
/// **No privilege escalation, by design.** `install()` only ever writes into
/// `binDirectory`, which defaults to `~/.local/bin` — owned by the user, so a
/// plain `createSymbolicLink` suffices. The obvious alternative,
/// `/usr/local/bin`, is `root:wheel` and would require a privileged helper or
/// running a shell as root from an app that also holds Keychain secrets. That
/// attack surface buys nothing the user cannot get by pasting one command, so
/// `systemWideInstallCommand` hands them that command as text and the app runs
/// no shell, no `sudo`, and no authorization API at all.
///
/// Core stays bundle-free (same rule as `UpdateCheckModel`'s version lookup):
/// the App layer derives `toolURL` from `Bundle.main.executableURL` and passes
/// it in.
public struct CLIToolInstaller: Sendable {
    /// The shortcut's file name, and the name the user types.
    public static let toolName = "macscp-cli"

    /// `~/.local/bin` — the conventional user-owned `bin` directory, and the
    /// only place this type ever writes.
    public static var defaultBinDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
    }

    /// The directory the shortcut is created in.
    public let binDirectory: URL
    /// The running app's own `macscp-cli` binary — what the shortcut must
    /// point at to count as `.installed`.
    public let toolURL: URL

    public init(binDirectory: URL = CLIToolInstaller.defaultBinDirectory, toolURL: URL) {
        self.binDirectory = binDirectory
        self.toolURL = toolURL
    }

    /// Absolute path of the shortcut itself.
    public var linkURL: URL {
        binDirectory.appendingPathComponent(Self.toolName)
    }

    /// Whether `url` sits inside an App Translocation mount.
    ///
    /// Gatekeeper runs a quarantined app — one opened straight off a mounted
    /// DMG, or from `~/Downloads` without being moved in Finder — from a
    /// randomised read-only copy at
    /// `/private/var/folders/…/AppTranslocation/<UUID>/d/macSCP.app`. That
    /// path is gone once the app quits. A shortcut created there is dead on
    /// arrival, so `state()` reports it before anything else and `install()`
    /// refuses.
    ///
    /// **Why the path marker and not `SecTranslocateIsTranslocatedURL`.**
    /// That function is the official API and the symbol is present in
    /// Security.framework (verified with `dlsym`) — but it is invisible to
    /// Swift: `import Security` does not declare it, because `SecTranslocate.h`
    /// is not in the framework's module map. Reaching it would mean adding a
    /// C shim target to `Package.swift`, or a hand-written `@convention(c)`
    /// cast over `dlsym` — an unchecked ABI declaration, retyped by hand, for
    /// one Boolean. The marker below needs neither, and it is directly
    /// testable, which matters more here than anywhere: the whole failure mode
    /// being fixed is one that looks successful. Every translocated path
    /// contains this component; the mount point is the mechanism, not an
    /// incidental detail of it.
    ///
    /// The costs are lopsided in the marker's favour. A false positive needs a
    /// directory literally named `AppTranslocation` on the app's own path, and
    /// costs a refusal that names the reason — with the copyable
    /// `/usr/local/bin` command still right there. A false negative is the
    /// green lie.
    public static func isTranslocated(_ url: URL) -> Bool {
        url.standardizedFileURL.path(percentEncoded: false).contains("/AppTranslocation/")
    }

    public func state() -> CLIInstallState {
        // Checked FIRST, and it overrides every other verdict: while
        // translocated, `toolURL` names a path that will not exist shortly.
        // Comparing an existing, perfectly good shortcut against it would
        // otherwise read `.stale` and invite a "Repair" that breaks it.
        if Self.isTranslocated(toolURL) { return .translocated }
        let path = linkURL.path(percentEncoded: false)
        // `attributesOfItem` is an `lstat`, so it describes the SYMLINK
        // rather than whatever it points at — which is the whole point here:
        // a dangling link must still read as a link, not as "nothing".
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return .notInstalled
        }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
            return .occupied
        }
        guard
            let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
        else {
            // A symlink whose destination cannot be read at all. Stale, with
            // NO target: the only path in hand is the link's own, and
            // reporting that would render as "points at ~/.local/bin/macscp-cli"
            // — a sentence that is never true. Repair still applies, since
            // replacing a symlink destroys no user data.
            return .stale(target: nil)
        }
        let resolved = absolute(destination)
        guard Self.canonical(resolved) == Self.canonical(toolURL) else {
            return .stale(target: resolved.path(percentEncoded: false))
        }
        return .installed
    }

    /// Creates (or repairs) the shortcut, creating `binDirectory` if it does
    /// not exist yet. Idempotent: a shortcut that already points at this app
    /// is left untouched and no error is raised.
    ///
    /// Throws `CLIInstallError.pathOccupied` when something that is not a
    /// symlink sits at `linkURL` — the one case where writing would destroy
    /// data the user owns — and `CLIInstallError.appIsTranslocated` when the
    /// running app would only be linkable to a mount that is about to vanish.
    public func install() throws {
        switch state() {
        case .installed:
            return
        case .occupied:
            throw CLIInstallError.pathOccupied(linkURL.path(percentEncoded: false))
        case .translocated:
            throw CLIInstallError.appIsTranslocated
        case .stale:
            // Only ever a symlink at this point (see `state()`), so removing
            // it discards a pointer, never content.
            try FileManager.default.removeItem(at: linkURL)
        case .notInstalled:
            break
        }
        try FileManager.default.createDirectory(
            at: binDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: toolURL)
    }

    /// The ready-made command for users who prefer the system-wide
    /// `/usr/local/bin`. **Displayed for copying, never executed** — the app
    /// spawns no process for it and holds no elevated rights.
    ///
    /// The tool path is single-quoted (embedded `'` escaped as `'\''`, the
    /// standard technique, same as `SSHCommandBuilder`) so an app installed
    /// under a path containing a space or a shell metacharacter still yields
    /// one correct command.
    public var systemWideInstallCommand: String {
        let quoted = Self.posixSingleQuote(toolURL.path(percentEncoded: false))
        return "sudo mkdir -p /usr/local/bin && sudo ln -sf \(quoted) /usr/local/bin/\(Self.toolName)"
    }

    /// Turns a symlink destination into an absolute URL. `ln -s` happily
    /// writes a relative destination, which is resolved against the LINK's
    /// own directory — not the process's working directory.
    private func absolute(_ destination: String) -> URL {
        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination).standardizedFileURL
        }
        return URL(fileURLWithPath: destination, relativeTo: binDirectory)
            .standardizedFileURL
    }

    /// Comparison form for two paths that should mean the same file.
    /// `resolvingSymlinksInPath` is what makes `/var/folders/…` and
    /// `/private/var/folders/…` compare equal (macOS symlinks `/var`), and it
    /// resolves as far as it can even when the leaf does not exist — so a
    /// dangling destination still compares sanely. Used ONLY for comparison;
    /// the target reported to the user stays the literal path the link names.
    private static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }

    private static func posixSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
