import Foundation

/// The package's `Sources/` and `Tests/` trees — each file read and blanked
/// at most once per test process — for every source-scanning guard in both
/// test targets.
///
/// ## Why this exists
///
/// Every guard used to list, read and blank the files it scans on its own,
/// on every call. Measured on 2026-09-19 with `sample` on the Core test
/// process: the source-scanning guards held 33.8 s of the cooperative
/// pool's 46.2 s of CPU in that window, and on the three-core CI runner the
/// same guards took 45–61 s each — long enough that tests which only needed
/// a thread for a millisecond waited more than 60 s for one and went red on
/// their time limits (CI runs 35405472152 and 35424079396). The work was the
/// same work, repeated: the same files read and blanked again by every
/// `@Test` that looked at them.
///
/// So each file is read and blanked once, lazily, the first time anything
/// asks for it, and every guard reads through the corpus.
///
/// ## What it holds
///
/// Per root (`Sources/`, `Tests/`): every regular file the
/// `FileManager` enumerator finds under it, in the enumerator's order, and
/// every directory — the LISTING, walked once per root and remembered.
/// Per file, lazily and only for the files somebody asks about: its text
/// (`nil` for a file that is not UTF-8, such as a `.DS_Store`) and the two
/// `SwiftSource` views of a `.swift` file — `blankingCommentsAndStrings`
/// (`code(of:)`) and `blankingComments` (`commentFree(of:)`). A guard that
/// scans the raw text, or a view of its own, reads `text(of:)` and derives
/// it.
///
/// ## Nobody waits for anybody else's work
///
/// Every table is a `PerKeyCache`: a reader that misses computes the value
/// itself, outside the lock, and publishes it in a short critical section;
/// two readers racing on one file both compute it once. A single-file guard
/// pays for one file, a walk for the files it touches, and no reader parks
/// its thread — a pool thread, or the main thread in a `@MainActor` suite —
/// behind a build another reader started. That includes the listing: two
/// first readers of a root both walk it rather than one waiting for the
/// other. A walk lists names and asks one resource value per entry; it
/// reads no file. Measured 2026-09-19, ten walks each, `-Onone`: `Sources/`
/// (399 files) 6.1–15.6 ms, median 7.9 ms; `Tests/` (523 files)
/// 6.8–8.1 ms, median 6.9 ms.
///
/// The first form of this type (commit `b22d20ca`) kept six whole-root
/// tables in `static let`s and made every other reader wait in Swift's
/// one-time initialisation while one reader built a whole root; the
/// numbers are in `PerKeyCache`'s doc comment.
///
/// ## What it refuses to do
///
/// It never serves a file it does not hold. A URL outside both roots, a
/// directory the walk did not find, a file that is not text, or a view
/// asked of a file that is not Swift throws — a guard pointed at the wrong
/// place fails, exactly as `String(contentsOf:)` failed before, instead of
/// scanning nothing and passing.
///
/// It is a snapshot. A test that writes files on purpose — a fixture tree
/// in a temporary directory, planted to exercise a scanner — reads those
/// from disk, not from here; nothing under `Sources/` or `Tests/` is
/// written by any test. `SourceCorpusScopeTests` pins that every listing
/// here equals a direct walk of the same directory, so a guard cannot
/// silently start scanning less than the tree holds.
public enum SourceCorpus {
    /// The two trees the corpus holds, by their directory name under the
    /// package root.
    public enum Root: String, CaseIterable, Sendable {
        case sources = "Sources"
        case tests = "Tests"
    }

    public enum CorpusError: Error, CustomStringConvertible {
        /// The path is outside both roots, or no file or directory at it
        /// was found by the walk.
        case notInCorpus(String)
        /// The file is in the corpus but did not decode as UTF-8.
        case notText(String)
        /// A blanked view was asked of a file that is not `.swift`.
        case notSwift(String)
        /// The walk itself reported an error; nothing it built is trusted.
        case walkFailed(String)
        /// A blanked view is not as long, in `Character`s, as the text it
        /// was made from — the property every guard that slices one view by
        /// offsets found in the other relies on.
        case viewLengthDiffers(String)

        public var description: String {
            switch self {
            case .notInCorpus(let path): "not in the source corpus: \(path)"
            case .notText(let path): "not a UTF-8 text file: \(path)"
            case .notSwift(let path): "not a Swift file, so it has no blanked view: \(path)"
            case .walkFailed(let reason): "the source corpus walk failed: \(reason)"
            case .viewLengthDiffers(let path):
                "a blanked view is not as long as the text it came from: \(path)"
            }
        }
    }

    /// `#filePath` is `<packageRoot>/Tests/MacSCPTestSupport/SourceCorpus.swift`,
    /// so three `deletingLastPathComponent()` calls reach the package root
    /// whatever `swift test`'s working directory is.
    public static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The root directory's URL.
    public static func url(of root: Root) -> URL {
        packageRoot.appendingPathComponent(root.rawValue, isDirectory: true)
    }

    // MARK: - Reading

    /// The file's text, exactly as `String(contentsOf:encoding: .utf8)`
    /// read it the first time anything in this process asked for it.
    public static func text(of url: URL) throws -> String {
        let key = try locate(url)
        let text = texts.value(for: key) { try? String(contentsOf: URL(fileURLWithPath: key), encoding: .utf8) }
        guard let text else { throw CorpusError.notText(key) }
        return text
    }

    /// `SwiftSource.blankingCommentsAndStrings` of the file: comments and
    /// string literals blanked, length and lines preserved. Throws what
    /// that call threw for this file (an unterminated literal).
    public static func code(of url: URL) throws -> String {
        try view(of: url, cache: codeViews, blank: SwiftSource.blankingCommentsAndStrings)
    }

    /// `SwiftSource.blankingComments` of the file: comments blanked,
    /// string literals kept. Throws what that call threw for this file.
    public static func commentFree(of url: URL) throws -> String {
        try view(of: url, cache: commentFreeViews, blank: SwiftSource.blankingComments)
    }

    /// `code(of:)` for each of `urls`, in order. For walks: readers that walk
    /// the same files at the same moment share the blanking file by file
    /// (`PerKeyCache.values(for:compute:)`) instead of each doing all of it.
    public static func code(ofAll urls: [URL]) throws -> [String] {
        try views(of: urls, cache: codeViews, blank: SwiftSource.blankingCommentsAndStrings)
    }

    /// `commentFree(of:)` for each of `urls`, in order, shared the same way.
    public static func commentFree(ofAll urls: [URL]) throws -> [String] {
        try views(of: urls, cache: commentFreeViews, blank: SwiftSource.blankingComments)
    }

    /// `blank(text)`, refused unless it is exactly as long as `text` in
    /// `Character`s. Every view the corpus serves goes through this, once
    /// per file — so a stripper that stopped preserving length fails every
    /// read of every file, not only those a particular scanner happens to
    /// compare two views of. Public so `SourceCorpusScopeTests` can drive it
    /// with a stripper that drops a character.
    public static func lengthCheckedView(
        of text: String, path: String, blank: (String) throws -> String
    ) throws -> String {
        let view = try blank(text)
        guard view.count == text.count else { throw CorpusError.viewLengthDiffers(path) }
        return view
    }

    // MARK: - Listing

    /// Every regular file under `directory`, at any depth, in the order the
    /// `FileManager` enumerator yields them — what
    /// `enumerator(at: directory, includingPropertiesForKeys: nil)` finds,
    /// minus the directories it also yields. Throws for a directory the
    /// walk did not find.
    public static func files(under directory: URL) throws -> [URL] {
        let (listing, directoryKey) = try locateDirectory(directory)
        let prefix = directoryKey + "/"
        return listing.keys.indices.filter { listing.keys[$0].hasPrefix(prefix) }.map { listing.urls[$0] }
    }

    /// `files(under:)` as paths relative to `directory` — what
    /// `enumerator(atPath:)` or `subpathsOfDirectory(atPath:)` yields, minus
    /// the directories both also yield.
    public static func relativePaths(under directory: URL) throws -> [String] {
        let prefix = key(directory) + "/"
        return try files(under: directory).map { String(key($0).dropFirst(prefix.count)) }
    }

    /// The regular files directly inside `directory` (no descent), in
    /// enumerator order. Throws for a directory the walk did not find.
    public static func children(of directory: URL) throws -> [URL] {
        let (listing, directoryKey) = try locateDirectory(directory)
        let prefix = directoryKey + "/"
        return listing.keys.indices.filter {
            let key = listing.keys[$0]
            return key.hasPrefix(prefix) && !key.dropFirst(prefix.count).contains("/")
        }.map { listing.urls[$0] }
    }

    /// Every directory under `root` the walk found (the root itself
    /// excluded), as keys — standardized absolute paths with no trailing
    /// separator. For `SourceCorpusScopeTests`.
    public static func directories(in root: Root) throws -> [String] {
        let listing = self.listing(root)
        if let failure = listing.failure { throw CorpusError.walkFailed(failure) }
        return listing.directories.sorted()
    }

    /// Whether `url` is a file the corpus holds.
    public static func contains(_ url: URL) -> Bool {
        (try? locate(url)) != nil
    }

    /// Whether `url` lies under one of the corpus roots — whether or not
    /// anything is there. A scanner that also runs over a fixture tree a
    /// test wrote to a temporary directory asks this to choose between the
    /// corpus and the disk: by where the path points, never by whether a
    /// corpus read happened to fail, so a mistyped path under `Sources/`
    /// still throws instead of falling back to an empty walk.
    public static func covers(_ url: URL) -> Bool {
        root(containing: key(url)) != nil
    }

    /// The path form every lookup here compares: standardized, absolute,
    /// not percent-encoded, no trailing separator.
    public static func key(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // MARK: - The walk

    /// One walk of one directory: its regular files in enumerator order and
    /// its directories, or the reason the walk cannot be trusted.
    public struct Listing: Sendable {
        public let rootKey: String
        /// Regular files, in enumerator order; `keys` and `urls` share one
        /// indexing.
        public let keys: [String]
        public let urls: [URL]
        public let directories: Set<String>
        /// Every error the walk met, joined; `nil` when there was none. A
        /// listing with a failure is never served — every read throws
        /// `walkFailed` instead.
        public let failure: String?
        let index: Set<String>
    }

    /// Walks `rootURL` with the `FileManager` enumerator. `resourceValues`
    /// is the one call per entry that tells a file from a directory; it is
    /// a parameter so `SourceCorpusScopeTests` can make it throw.
    public static func walk(
        _ rootURL: URL,
        resourceValues: (URL) throws -> URLResourceValues = {
            try $0.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        }
    ) -> Listing {
        let rootKey = key(rootURL)
        let errors = ErrorLog()
        var keys: [String] = []
        var urls: [URL] = []
        var directories: Set<String> = []
        if let walker = FileManager.default.enumerator(
            at: rootURL, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            errorHandler: { url, error in
                errors.append("\(url.path(percentEncoded: false)): \(error)")
                return true
            })
        {
            for case let url as URL in walker {
                // An entry the walk cannot classify is a failure of the walk,
                // never an entry quietly left out of both lists.
                let values: URLResourceValues
                do {
                    values = try resourceValues(url)
                } catch {
                    errors.append("\(url.path(percentEncoded: false)): \(error)")
                    continue
                }
                if values.isDirectory == true {
                    directories.insert(key(url))
                } else if values.isRegularFile == true {
                    keys.append(key(url))
                    urls.append(url)
                }
            }
        } else {
            errors.append("cannot enumerate \(rootKey)")
        }
        if keys.isEmpty { errors.append("no file under \(rootKey)") }
        return Listing(
            rootKey: rootKey, keys: keys, urls: urls, directories: directories,
            failure: errors.entries.isEmpty ? nil : errors.entries.joined(separator: "; "),
            index: Set(keys))
    }

    // MARK: - The tables

    private static let listings = PerKeyCache<Listing>()
    private static let texts = PerKeyCache<String?>()
    private static let codeViews = PerKeyCache<Result<String, any Error>>()
    private static let commentFreeViews = PerKeyCache<Result<String, any Error>>()

    private static func listing(_ root: Root) -> Listing {
        listings.value(for: root.rawValue) { walk(url(of: root)) }
    }

    /// Which root a key belongs to, by prefix — without walking either, so
    /// asking about a path outside both costs nothing.
    private static func root(containing key: String) -> Root? {
        Root.allCases.first { key == Self.key(url(of: $0)) || key.hasPrefix(Self.key(url(of: $0)) + "/") }
    }

    /// The key of a file the corpus holds, or the reason it does not.
    private static func locate(_ url: URL) throws -> String {
        let key = key(url)
        guard let root = root(containing: key) else { throw CorpusError.notInCorpus(key) }
        let listing = listing(root)
        if let failure = listing.failure { throw CorpusError.walkFailed(failure) }
        guard listing.index.contains(key) else { throw CorpusError.notInCorpus(key) }
        return key
    }

    private static func locateDirectory(_ url: URL) throws -> (Listing, String) {
        let key = key(url)
        guard let root = root(containing: key) else { throw CorpusError.notInCorpus(key) }
        let listing = listing(root)
        if let failure = listing.failure { throw CorpusError.walkFailed(failure) }
        guard key == listing.rootKey || listing.directories.contains(key) else {
            throw CorpusError.notInCorpus(key)
        }
        return (listing, key)
    }

    private static func view(
        of url: URL, cache: PerKeyCache<Result<String, any Error>>,
        blank: (String) throws -> String
    ) throws -> String {
        let key = try locate(url)
        guard url.pathExtension == "swift" else { throw CorpusError.notSwift(key) }
        let text = try text(of: url)
        return try cache.value(for: key) {
            Result { try lengthCheckedView(of: text, path: key, blank: blank) }
        }.get()
    }

    private static func views(
        of urls: [URL], cache: PerKeyCache<Result<String, any Error>>,
        blank: (String) throws -> String
    ) throws -> [String] {
        let keys = try urls.map { url in
            let key = try locate(url)
            guard url.pathExtension == "swift" else { throw CorpusError.notSwift(key) }
            return key
        }
        let sources = try urls.map { try text(of: $0) }
        return try cache.values(for: keys) { index in
            Result { try lengthCheckedView(of: sources[index], path: keys[index], blank: blank) }
        }.map { try $0.get() }
    }

    /// Collects the walk's errors; only ever touched from the thread that
    /// runs the walk, synchronously, but the enumerator's handler is an
    /// escaping closure, so it gets a reference rather than a captured var.
    private final class ErrorLog {
        var entries: [String] = []
        func append(_ entry: String) { entries.append(entry) }
    }
}
