import Foundation

/// The scan behind `SourceCorpus`'s own claim that "nothing under `Sources/`
/// or `Tests/` is written by any test".
///
/// That claim is load-bearing and, until this file, unenforced (backlog: "The
/// source-corpus guard plan's deferred minors", M6). The corpus reads a file
/// the first time anything in a process asks for it, so a test that wrote to
/// a tree file mid-run would be read before or after its write depending on
/// which test ran first — per-file caching makes the staleness different, not
/// safer. Two guards reading the same file would then disagree about what the
/// tree says, and neither would say why.
///
/// It is a scan and not a runtime check because there is no moment to check
/// at: a snapshot taken before the suite cannot see a write that happens
/// after it, and a comparison at the end cannot tell which test did it. What
/// CAN be decided statically is whether a write API is ever handed a path
/// rooted at the package.
///
/// ## What it reads
///
/// One site is a write API's own argument list — the text between the
/// marker's `(` and the `)` that balances it — and it is a violation when a
/// PACKAGE-ROOT spelling appears inside that list. Reading the argument list
/// rather than the line or the file is the whole point: a test that reads
/// source through `repoRoot` and writes fixtures into a temporary directory
/// does both in one file, usually in one function, and a file-level or
/// line-level check would call every one of them a violation.
///
/// ## What it cannot see
///
/// A root path bound to a local first (`let target = repoRoot.appending(…)`
/// then `try data.write(to: target)`) passes: the argument list names only
/// `target`. That is the known hole, and it is the same hole every scan of
/// this kind in this project has — a guard, not a proof. What it does catch
/// is the shape a write under the tree is actually written in, which is
/// directly, because a test doing it is doing it by accident.
///
/// Measured on 2026-09-27, four violations planted in a real test file and
/// run three times each: the direct write, the multi-line write whose root
/// spelling sits two lines below the call, and a `removeItem(at:)` under the
/// tree were RED 3/3; the local-binding form above was GREEN 3/3. That last
/// number is the hole, stated as a number rather than as a worry.
public enum TreeWriteScan {
    /// File-writing APIs, each spelled with the `(` its argument list opens
    /// with, so a site's span is found from the marker itself.
    ///
    /// The leading `.` matters twice: it keeps a declaration (`func
    /// write(to:`) out of the scan, and it stops `moveItem(` from matching
    /// inside `removeItem(` — measured 2026-09-27, when the undotted pair
    /// reported the same 1023 occurrences for both, because `removeItem(`
    /// ends in `moveItem(`.
    ///
    /// No argument label is spelled either, so a call written across lines
    /// (`try data.write(\n    to: url)`) is one site like any other. The
    /// label-carrying form `.write(to:` was the first draft, and it read
    /// past exactly that shape.
    ///
    /// These are the spellings that produce at least one site in the files
    /// this scan examines, measured there on 2026-09-27 — not counted over
    /// the whole of `Tests/`, because this file spells all of them as string
    /// literals and would count itself.
    public static let liveMarkers = [
        ".write(", ".createFile(", ".removeItem(", ".copyItem(",
        ".createDirectory(", ".createSymbolicLink(",
    ]

    /// Write APIs with no site in the examined files on 2026-09-27. They
    /// are scanned anyway — a scan costs nothing per absent spelling — but
    /// nothing asserts they match, because a check that requires an absence
    /// AND finds nothing to be absent in is the shape CLAUDE.md calls a
    /// comment that runs. `liveMarkers` is the positive that keeps this
    /// whole list honest.
    public static let dormantMarkers = [
        ".moveItem(", ".replaceItemAt(", ".linkItem(", ".trashItem(",
        "FileHandle(forWritingTo:", "FileHandle(forUpdatingTo:",
    ]

    public static var markers: [String] { liveMarkers + dormantMarkers }

    /// How a test addresses the package root. Counted over `Tests/` on
    /// 2026-09-27 the same way: `repoRoot` 403, `#filePath` 215,
    /// `SourceCorpus.url(of:` 23, `packageRoot` 5 — which subsumes
    /// `SourceCorpus.packageRoot`, so that longer spelling is not listed
    /// separately.
    public static let rootSpellings = [
        "repoRoot", "packageRoot", "#filePath", "SourceCorpus.url(of:",
    ]

    /// One call to a write API: which one, where, and what it was handed.
    public struct Site: Sendable {
        public let file: String
        /// 1-based, counted in the blanked view, whose lines are the file's.
        public let line: Int
        public let marker: String
        /// The text between the marker's `(` and the `)` that balances it.
        public let arguments: String

        /// The root spellings named inside the argument list.
        public func rootsNamed(among spellings: [String]) -> [String] {
            spellings.filter { arguments.contains($0) }
        }
    }

    /// Every write-API call site in `source`, which must be a blanked view —
    /// `SourceCorpus.code`, so a sentence describing a write cannot become
    /// one, and a path written as a string literal cannot either. A literal
    /// path INTO the tree (`"Sources/…"` with no root spelling beside it)
    /// is relative to the process's working directory, not to the package,
    /// and is not what this scan is about.
    public static func sites(in source: String, file: String, markers: [String]) -> [Site] {
        var found: [Site] = []
        for marker in markers {
            guard let openIndex = marker.firstIndex(of: "(") else { continue }
            let afterOpen = marker.distance(from: marker.startIndex, to: openIndex) + 1
            var search = source.startIndex..<source.endIndex
            while let hit = source.range(of: marker, range: search) {
                search = hit.upperBound..<source.endIndex
                let listStart = source.index(hit.lowerBound, offsetBy: afterOpen)
                guard let close = closingParen(from: listStart, in: source) else { continue }
                found.append(Site(
                    file: file,
                    line: source[..<hit.lowerBound].filter { $0 == "\n" }.count + 1,
                    marker: marker,
                    arguments: String(source[listStart..<close])))
            }
        }
        return found
    }

    /// The index of the `)` that balances the `(` just before `start`.
    private static func closingParen(from start: String.Index, in source: String) -> String.Index? {
        var depth = 1
        var index = start
        while index < source.endIndex {
            if source[index] == "(" { depth += 1 }
            if source[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
