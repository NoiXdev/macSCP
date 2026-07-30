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
    /// names). Uses `RemotePath.normalizedAbsolute` instead — the one
    /// `RemotePath` function explicitly safe on hostile input — so
    /// repeated/trailing slashes in hand-typed input can't produce a bogus
    /// directory; the root always normalizes to `"/"`.
    ///
    /// `input` is required to be absolute. A bare relative fragment with no
    /// slash at all (e.g. `"ho"`) still returns `"/"` here — there is no
    /// notion of "the current directory" to fall back to relative to. The
    /// path bar never hits this in practice because the field is always
    /// pre-filled with the current absolute directory, but a caller that
    /// passed a genuinely relative string would silently get root rather
    /// than a relative completion.
    public static func directoryToList(for input: String) -> String {
        guard let lastSlash = input.lastIndex(of: "/") else {
            return "/"
        }
        return RemotePath.normalizedAbsolute(String(input[..<lastSlash]))
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

        // Multiple candidates: only extend the input if the shared prefix
        // both is at least as long as what's typed AND differs from it.
        //
        // The length check is NOT redundant, despite `caseSensitive: true`
        // making it look that way: there, every match satisfies
        // `hasPrefix(typed)`, so `commonPrefix.count >= typed.count` always
        // holds and a pure length check could never fire on its own — a
        // prior pass over this code dropped the length half of the guard on
        // exactly that reasoning. But with `caseSensitive: false`, matches
        // only satisfy `hasPrefix(typed)` case-INsensitively; their real
        // spellings can disagree with each other in case (e.g. "Desktop"
        // and "dev" both match typed "d"), so the longest common PREFIX OF
        // THE REAL NAMES can be shorter than `typed` — even empty. Without
        // the length check, `commonPrefix != typed` alone is true for that
        // short prefix too, and the code below would replace the user's
        // typed text with something shorter, deleting characters they just
        // typed. The length check catches that case; what's left for the
        // equality check is the same-length spelling mismatch: several
        // entries can share a prefix that is the SAME LENGTH as `typed` but
        // differently cased (real "Do..." vs typed "do") — that's still a
        // completion the user needs, so the real spelling must win even
        // when the count doesn't grow.
        guard commonPrefix.count >= typed.count, commonPrefix != typed else {
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
}
