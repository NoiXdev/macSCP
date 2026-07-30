import Foundation

/// Pure, I/O-free shell-style path completion for the remote browser's
/// editable path field (M11g/T1). This never lists anything itself:
/// `directoryToList(for:)` tells the caller which directory to `list()`,
/// and `complete` is then handed that listing to work with — keeping the
/// whole thing trivially unit-testable and reusable from the gated rig test
/// that proves the pieces actually agree with a REAL listing.
public enum PathCompletion {
    /// `complete`'s result. `completedInput` is what the text field should
    /// show after a Tab keypress — unchanged from the input when nothing
    /// can be completed further. `candidates` is the alphabetically sorted
    /// (`localizedCaseInsensitiveCompare`) list of matching directory names,
    /// for a candidates popover.
    public struct Result: Equatable, Sendable {
        public let completedInput: String
        public let candidates: [String]

        public init(completedInput: String, candidates: [String]) {
            self.completedInput = completedInput
            self.candidates = candidates
        }
    }

    /// The directory the caller must `list()` before calling `complete`
    /// with the result: everything in `input` up to (excluding) the last
    /// `/` names that directory; whatever follows the last `/` is the
    /// partial component being completed. Deliberately does NOT delegate to
    /// `RemotePath.parent(of:)`: that function's contract is "parent of an
    /// EXISTING path", and its trailing-slash handling means something
    /// different there (`"/var/www/"` would parent to `"/var"`, not stay at
    /// `"/var/www"` — the directory a trailing slash on typed input actually
    /// names). Normalizes independently so repeated/trailing slashes in
    /// hand-typed input can't produce a bogus directory; the root always
    /// normalizes to `"/"`.
    public static func directoryToList(for input: String) -> String {
        guard let lastSlash = input.lastIndex(of: "/") else {
            return "/"
        }
        return normalize(String(input[..<lastSlash]))
    }

    /// Completes `input` against `entries` — the listing of
    /// `directoryToList(for: input)`.
    ///
    /// Only directories are ever candidates: the field this feeds always
    /// means "directory to jump to", and a file can't be navigated into.
    /// Symlinks are excluded too — without a `stat` call this function has
    /// no way to know whether a symlink's target is a directory, the same
    /// restraint `PermissionsTreeApplier` applies (for a different reason;
    /// see its doc comments) rather than resolve anything itself.
    /// `caseSensitive` has no default: macOS filesystems are commonly
    /// case-insensitive but SFTP servers are not, and silently picking one
    /// behavior for both would be wrong for the other — callers must decide.
    public static func complete(
        input: String, entries: [RemoteFileItem], caseSensitive: Bool
    ) -> Result {
        let lastSlash = input.lastIndex(of: "/")
        let typed = lastSlash.map { String(input[input.index(after: $0)...]) } ?? input
        let directories = entries.filter { $0.isDirectory }

        let matches: [RemoteFileItem]
        if typed.isEmpty {
            matches = directories
        } else if caseSensitive {
            matches = directories.filter { $0.name.hasPrefix(typed) }
        } else {
            let lowerTyped = typed.lowercased()
            matches = directories.filter { $0.name.lowercased().hasPrefix(lowerTyped) }
        }

        let candidateNames = matches.map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        guard !matches.isEmpty else {
            return Result(completedInput: input, candidates: candidateNames)
        }

        let directory = directoryToList(for: input)
        // The common prefix is computed in the case of the REAL entries,
        // never the typed text: with `caseSensitive: false` the user may
        // have typed "d" against a folder actually named "Docs" — completing
        // to "d" instead of "D" would silently mismatch a case-sensitive
        // SFTP server on the very next keystroke.
        let commonPrefix = longestCommonPrefix(of: matches.map(\.name))

        if matches.count == 1 {
            // A single match completes all the way, with a trailing slash
            // so the user can keep typing straight into the next segment.
            return Result(
                completedInput: RemotePath.join(directory, commonPrefix) + "/",
                candidates: candidateNames)
        }

        // Multiple candidates: only extend the input if their shared prefix
        // reaches further than what's already typed (e.g. "html"/"hosts"
        // share only "h", which is already typed — nothing to add yet).
        guard commonPrefix.count > typed.count else {
            return Result(completedInput: input, candidates: candidateNames)
        }
        return Result(
            completedInput: RemotePath.join(directory, commonPrefix),
            candidates: candidateNames)
    }

    /// Longest common prefix shared by every name in `names` (empty if
    /// `names` is empty or shares no prefix at all).
    private static func longestCommonPrefix(of names: [String]) -> String {
        guard var prefix = names.first else { return "" }
        for name in names.dropFirst() {
            while !name.hasPrefix(prefix) {
                prefix.removeLast()
                if prefix.isEmpty { return "" }
            }
        }
        return prefix
    }

    /// Collapses any run of consecutive slashes and drops every trailing
    /// slash; the empty string and the root both normalize to `"/"`.
    private static func normalize(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }
}
