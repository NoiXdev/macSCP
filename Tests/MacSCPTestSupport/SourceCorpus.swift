import Foundation

/// The package's `Sources/` and `Tests/` trees, read once per test process,
/// for every source-scanning guard in both test targets.
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
/// So the corpus is built once, lazily, the first time anything asks, and
/// every guard reads through it.
///
/// ## What it holds
///
/// Per root (`Sources/`, `Tests/`): every regular file the
/// `FileManager` enumerator finds under it, in the enumerator's order, with
/// its text (`nil` for a file that is not UTF-8, such as a `.DS_Store`).
/// Per root and per mode, the two `SwiftSource` views of every `.swift`
/// file — `blankingCommentsAndStrings` (`code(of:)`) and `blankingComments`
/// (`commentFree(of:)`). A guard that scans the raw text, or a view of its
/// own, reads `text(of:)` and derives it.
///
/// Each of those six tables is a `static let` of an immutable value: Swift
/// initialises a global exactly once and publishes it to every thread, so
/// the read path takes no lock. The first reader of a table builds it on
/// its own thread (the views in parallel through `concurrentPerform`, whose
/// caller also takes iterations, so the build needs no other thread to
/// finish); a second reader that arrives meanwhile waits for that build and
/// nothing else, which is the cost it would otherwise have paid itself.
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

        public var description: String {
            switch self {
            case .notInCorpus(let path): "not in the source corpus: \(path)"
            case .notText(let path): "not a UTF-8 text file: \(path)"
            case .notSwift(let path): "not a Swift file, so it has no blanked view: \(path)"
            case .walkFailed(let reason): "the source corpus walk failed: \(reason)"
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
    /// read it when the corpus was built.
    public static func text(of url: URL) throws -> String {
        let (tree, index) = try locate(url)
        guard let text = tree.texts[index] else { throw CorpusError.notText(key(url)) }
        return text
    }

    /// `SwiftSource.blankingCommentsAndStrings` of the file: comments and
    /// string literals blanked, length and lines preserved. Throws what
    /// that call threw for this file (an unterminated literal).
    public static func code(of url: URL) throws -> String {
        try view(of: url, keepingStringLiterals: false)
    }

    /// `SwiftSource.blankingComments` of the file: comments blanked,
    /// string literals kept. Throws what that call threw for this file.
    public static func commentFree(of url: URL) throws -> String {
        try view(of: url, keepingStringLiterals: true)
    }

    // MARK: - Listing

    /// Every regular file under `directory`, at any depth, in the order the
    /// `FileManager` enumerator yields them — what
    /// `enumerator(at: directory, includingPropertiesForKeys: nil)` finds,
    /// minus the directories it also yields. Throws for a directory the
    /// walk did not find.
    public static func files(under directory: URL) throws -> [URL] {
        let (tree, directoryKey) = try locateDirectory(directory)
        let prefix = directoryKey + "/"
        return tree.keys.indices.filter { tree.keys[$0].hasPrefix(prefix) }.map { tree.urls[$0] }
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
        let (tree, directoryKey) = try locateDirectory(directory)
        let prefix = directoryKey + "/"
        return tree.keys.indices.filter {
            let key = tree.keys[$0]
            return key.hasPrefix(prefix) && !key.dropFirst(prefix.count).contains("/")
        }.map { tree.urls[$0] }
    }

    /// Every directory under `root` the walk found (the root itself
    /// excluded), as keys — standardized absolute paths with no trailing
    /// separator. For `SourceCorpusScopeTests`.
    public static func directories(in root: Root) throws -> [String] {
        let tree = self.tree(root)
        if let failure = tree.failure { throw CorpusError.walkFailed(failure) }
        return tree.directories.sorted()
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

    // MARK: - The tables

    private static let sourcesTree = Tree(walking: .sources)
    private static let testsTree = Tree(walking: .tests)
    private static let sourcesCode = Views(of: sourcesTree, keepingStringLiterals: false)
    private static let sourcesCommentFree = Views(of: sourcesTree, keepingStringLiterals: true)
    private static let testsCode = Views(of: testsTree, keepingStringLiterals: false)
    private static let testsCommentFree = Views(of: testsTree, keepingStringLiterals: true)

    private static func tree(_ root: Root) -> Tree {
        switch root {
        case .sources: sourcesTree
        case .tests: testsTree
        }
    }

    private static func views(_ root: Root, keepingStringLiterals: Bool) -> Views {
        switch (root, keepingStringLiterals) {
        case (.sources, false): sourcesCode
        case (.sources, true): sourcesCommentFree
        case (.tests, false): testsCode
        case (.tests, true): testsCommentFree
        }
    }

    /// Which root a key belongs to, by prefix — without touching either
    /// table, so asking about a path outside both builds nothing.
    private static func root(containing key: String) -> Root? {
        Root.allCases.first { key == Self.key(url(of: $0)) || key.hasPrefix(Self.key(url(of: $0)) + "/") }
    }

    private static func locate(_ url: URL) throws -> (Tree, Int) {
        let key = key(url)
        guard let root = root(containing: key) else { throw CorpusError.notInCorpus(key) }
        let tree = tree(root)
        if let failure = tree.failure { throw CorpusError.walkFailed(failure) }
        guard let index = tree.index[key] else { throw CorpusError.notInCorpus(key) }
        return (tree, index)
    }

    private static func locateDirectory(_ url: URL) throws -> (Tree, String) {
        let key = key(url)
        guard let root = root(containing: key) else { throw CorpusError.notInCorpus(key) }
        let tree = tree(root)
        if let failure = tree.failure { throw CorpusError.walkFailed(failure) }
        guard key == tree.rootKey || tree.directories.contains(key) else {
            throw CorpusError.notInCorpus(key)
        }
        return (tree, key)
    }

    private static func view(of url: URL, keepingStringLiterals: Bool) throws -> String {
        let (tree, index) = try locate(url)
        guard tree.urls[index].pathExtension == "swift" else { throw CorpusError.notSwift(key(url)) }
        guard tree.texts[index] != nil else { throw CorpusError.notText(key(url)) }
        let key = key(url)
        guard let root = root(containing: key), let result = views(root, keepingStringLiterals: keepingStringLiterals)
            .results[index]
        else { throw CorpusError.notSwift(key) }
        return try result.get()
    }

    /// One walk of one root.
    private struct Tree: Sendable {
        let rootKey: String
        /// Regular files, in enumerator order; `keys`, `urls` and `texts`
        /// share one indexing.
        let keys: [String]
        let urls: [URL]
        let texts: [String?]
        let index: [String: Int]
        let directories: Set<String>
        let failure: String?

        init(walking root: Root) {
            let rootURL = SourceCorpus.url(of: root)
            rootKey = SourceCorpus.key(rootURL)
            let errors = ErrorLog()
            var keys: [String] = []
            var urls: [URL] = []
            var texts: [String?] = []
            var directories: Set<String> = []
            let wanted: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
            if let walker = FileManager.default.enumerator(
                at: rootURL, includingPropertiesForKeys: wanted,
                errorHandler: { url, error in
                    errors.append("\(url.path(percentEncoded: false)): \(error)")
                    return true
                })
            {
                for case let url as URL in walker {
                    let values = try? url.resourceValues(forKeys: Set(wanted))
                    if values?.isDirectory == true {
                        directories.insert(SourceCorpus.key(url))
                    } else if values?.isRegularFile == true {
                        keys.append(SourceCorpus.key(url))
                        urls.append(url)
                        texts.append(try? String(contentsOf: url, encoding: .utf8))
                    }
                }
            } else {
                errors.append("cannot enumerate \(rootKey)")
            }
            if keys.isEmpty { errors.append("no file under \(rootKey)") }
            self.keys = keys
            self.urls = urls
            self.texts = texts
            self.directories = directories
            index = Dictionary(keys.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            failure = errors.entries.isEmpty ? nil : errors.entries.joined(separator: "; ")
        }
    }

    /// One blanked view of every `.swift` file in a tree, indexed like the
    /// tree; `nil` where the file is not Swift or not text.
    private struct Views: Sendable {
        let results: [Result<String, any Error>?]

        init(of tree: Tree, keepingStringLiterals: Bool) {
            let count = tree.urls.count
            nonisolated(unsafe) let slots = UnsafeMutableBufferPointer<Result<String, any Error>?>
                .allocate(capacity: count)
            slots.initialize(repeating: nil)
            defer {
                slots.deinitialize()
                slots.deallocate()
            }
            DispatchQueue.concurrentPerform(iterations: count) { index in
                guard tree.urls[index].pathExtension == "swift", let text = tree.texts[index] else { return }
                slots[index] = Result {
                    keepingStringLiterals
                        ? try SwiftSource.blankingComments(text)
                        : try SwiftSource.blankingCommentsAndStrings(text)
                }
            }
            results = Array(slots)
        }
    }

    /// Collects the walk's errors; only ever touched from the thread that
    /// runs the walk, synchronously, but the enumerator's handler is an
    /// escaping closure, so it gets a reference rather than a captured var.
    private final class ErrorLog {
        var entries: [String] = []
        func append(_ entry: String) { entries.append(entry) }
    }
}
