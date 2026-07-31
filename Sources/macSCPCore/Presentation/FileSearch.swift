import Foundation

/// How a non-empty search query affects the displayed listing (M11k).
public enum FileSearchMode: Sendable, Equatable {
    /// Only matching entries are shown; `items` shrinks to the matches.
    case filter
    /// The listing stays full; the selection is moved between matches.
    case jump
}

/// Search failure modes. Deliberately its own type rather than folding into
/// "zero matches": an invalid regex is a distinct, honest error the UI must
/// surface as such — never as a faked "0 results" (maintainer decision,
/// M11k design). This is a typed value with no localized text attached; the
/// App layer (T2) owns the user-facing phrasing, matching this task's
/// decision to keep `FileSearchError` translation-free in Core (see the
/// note in this file's header comment for the full rationale).
public enum FileSearchError: Error, Equatable, Sendable {
    case invalidRegex
}

/// Pure, testable name-search matcher and derivation for the CURRENT
/// directory listing of a single pane (M11k/T1). Bounded strictly to the
/// entries already loaded — no recursion into subdirectories, no additional
/// server round-trips (see the design doc's "Grenze" section).
///
/// Localization decision: `FileSearchError` is a typed value with no
/// attached message string, and no key was added to the Core
/// `Localizable.strings` catalogs for it. The one user-facing text this
/// milestone needs — "invalid regular expression" — is owned by the App
/// layer (Task 2), which maps the single `.invalidRegex` case to its own
/// localized string next to the search field. This mirrors the brief's
/// stated preference ("prefer to expose `FileSearchError` as a typed value
/// and let the App layer localize it") and avoids growing Core's catalog
/// for a message that has exactly one call site, entirely in the App UI.
public enum FileSearch {
    /// A compiled, reusable name predicate. Compilation (regex parsing in
    /// particular) happens once in `compile`/`derive`, never per row.
    public struct FileSearchPredicate: Sendable {
        /// `true` for an empty/blank query: matches everything, i.e. "no
        /// filter is active". Distinguishes "nothing typed" from "typed
        /// something with zero results" for callers that want to know.
        public let isEmpty: Bool
        private let matchFunction: @Sendable (String) -> Bool

        fileprivate init(isEmpty: Bool, matches: @escaping @Sendable (String) -> Bool) {
            self.isEmpty = isEmpty
            self.matchFunction = matches
        }

        public func matches(_ name: String) -> Bool {
            matchFunction(name)
        }
    }

    /// The result of applying a compiled predicate to a full listing.
    public struct Derivation: Equatable, Sendable {
        /// The listing to display: only the matches in `.filter` mode, the
        /// full input list (unfiltered) in `.jump` mode.
        public let visible: [RemoteFileItem]
        /// Paths of the matching entries, in listing order. Populated in
        /// both modes; `.jump` mode's caller uses it to walk matches.
        public let matchPaths: [String]
        public let matchCount: Int
        public let totalCount: Int

        public init(visible: [RemoteFileItem], matchPaths: [String], matchCount: Int, totalCount: Int) {
            self.visible = visible
            self.matchPaths = matchPaths
            self.matchCount = matchCount
            self.totalCount = totalCount
        }

        public static func == (lhs: Derivation, rhs: Derivation) -> Bool {
            lhs.visible == rhs.visible
                && lhs.matchPaths == rhs.matchPaths
                && lhs.matchCount == rhs.matchCount
                && lhs.totalCount == rhs.totalCount
        }
    }

    /// Compiles `query` into a reusable predicate.
    ///
    /// - An empty or whitespace-only query yields the "matches everything"
    ///   predicate (`isEmpty == true`) — no filter is applied.
    /// - `isRegex == false`: case-insensitive substring match on the name,
    ///   via `localizedCaseInsensitiveContains`. This follows `NSString`'s
    ///   comparison rules: case folding is Unicode-aware (e.g. "MÜLLER"
    ///   matches "müller"), but there is NO diacritic folding — a plain "u"
    ///   does not match "ü". Callers relying on looser diacritic-insensitive
    ///   matching would need a different comparison; this task intentionally
    ///   keeps to the simpler, documented `NSString` behavior.
    /// - `isRegex == true`: compiles an `NSRegularExpression` with
    ///   `.caseInsensitive` exactly once; a partial match anywhere in the
    ///   name counts. An invalid pattern is reported as `.invalidRegex`,
    ///   distinct from "compiled fine, zero matches".
    public static func compile(query: String, isRegex: Bool) -> Result<FileSearchPredicate, FileSearchError> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .success(FileSearchPredicate(isEmpty: true, matches: { _ in true }))
        }

        if isRegex {
            guard let regex = try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive]) else {
                return .failure(.invalidRegex)
            }
            return .success(FileSearchPredicate(isEmpty: false, matches: { name in
                let range = NSRange(name.startIndex..<name.endIndex, in: name)
                return regex.firstMatch(in: name, options: [], range: range) != nil
            }))
        }

        return .success(FileSearchPredicate(isEmpty: false, matches: { name in
            name.localizedCaseInsensitiveContains(trimmed)
        }))
    }

    /// Applies `query`/`isRegex` to `all` for the given `mode`, producing
    /// everything a view model needs to update its displayed listing in one
    /// step: the visible rows, the ordered match paths, and the two counts
    /// for a "N of M" readout.
    ///
    /// - `.filter`: `visible` is only the matching entries.
    /// - `.jump`: `visible` is `all` unchanged; `matchPaths` names which
    ///   entries (in listing order) the caller can jump between.
    /// - An invalid regex propagates as `.failure(.invalidRegex)` without
    ///   producing a `Derivation` at all — the caller (the view model) is
    ///   expected to leave its current `items` untouched on failure rather
    ///   than clearing it to an empty/zero-match state.
    public static func derive(
        all: [RemoteFileItem], query: String, isRegex: Bool, mode: FileSearchMode
    ) -> Result<Derivation, FileSearchError> {
        switch compile(query: query, isRegex: isRegex) {
        case .failure(let error):
            return .failure(error)
        case .success(let predicate):
            let matches = all.filter { predicate.matches($0.name) }
            let matchPaths = matches.map(\.path)
            let visible = mode == .filter ? matches : all
            return .success(Derivation(
                visible: visible, matchPaths: matchPaths,
                matchCount: matches.count, totalCount: all.count))
        }
    }
}
