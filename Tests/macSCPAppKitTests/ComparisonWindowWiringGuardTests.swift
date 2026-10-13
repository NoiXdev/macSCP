import Foundation
import MacSCPTestSupport
import Testing

/// The source-level half of the comparison window's ownership rule (diff
/// view, Task 9). `ComparisonWindowModelTests` holds the behaviour — what the
/// window does when its session is gone or its window closes; this holds what
/// no behaviour test can reach: that the scene is declared, that the window
/// reaches its tab only through the registry, that it resolves ONCE, and that
/// nothing it stores is a connection.
///
/// Every negative check has a positive one beside it asserting the thing it
/// scans is there at all.
///
/// **What the stored-property reader cannot see.** It reads one declaration
/// per line, at the top level of a type's body. A property whose type sits on
/// a continuation line, or one declared through a macro, is not read. The
/// positive checks below name the properties it DOES find, so a reader that
/// stopped finding them would fail loudly instead of passing over nothing.
@Suite("Comparison window wiring guard")
struct ComparisonWindowWiringGuardTests {
    private static let sources = SourceCorpus.url(of: .sources)
    private static let appKit = sources.appendingPathComponent("MacSCPAppKit")
    private static let windowFile = "ComparisonWindow.swift"

    private static func code(_ file: String) throws -> String {
        let view = try SourceCorpus.code(of: appKit.appendingPathComponent(file))
        return view.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "( ", with: "(")
            .replacingOccurrences(of: " )", with: ")")
    }

    /// A type's body with its original line structure, for the line reader.
    private static func body(_ declaration: String, in file: String) throws -> String {
        let source = try SourceCorpus.code(of: appKit.appendingPathComponent(file))
        return try TransferQueueBarCancelGuardTests.declarationBody(of: declaration, in: source)
    }

    private static func occurrences(of needle: String, in code: String) -> Int {
        code.components(separatedBy: needle).count - 1
    }

    // MARK: The scene

    @Test func theAppDeclaresTheComparisonWindowAsAThirdScene() throws {
        let app = try Self.code("MacSCPApp.swift")
        // Positive: the two scenes that were there are still there.
        #expect(app.contains("for: WindowSeed.self"))
        #expect(app.contains("Settings {"))
        // The new one: value-keyed on the seed, showing the window.
        #expect(app.contains("for: ComparisonSeed.self"))
        #expect(Self.occurrences(of: "for: ComparisonSeed.self", in: app) == 1)
        #expect(app.contains("ComparisonWindow(seed: seed)"))
        // Window restoration is off for it: a persisted seed names ids that
        // mean nothing after a relaunch.
        let scene = try #require(app.range(of: "for: ComparisonSeed.self"))
        let rest = String(app[scene.upperBound...].prefix(900))
        #expect(rest.contains(".restorationBehavior(.disabled)"))
    }

    /// The scene is additive. The registry, the menu-bar model, the close
    /// warning and the quit sequence know nothing of it; and the window knows
    /// nothing of them.
    @Test func theSceneTouchesNeitherTheRegistryTheMenuBarTheCloseWarningNorQuit() throws {
        let untouched = [
            "TabRegistry.swift", "MenuBarStatusModel.swift", "TabCloseWarning.swift",
            "QuitSequence.swift",
        ]
        for file in untouched {
            let code = try Self.code(file)
            // Positive: the file is read at all.
            #expect(!code.isEmpty, "\(file) read as empty")
            #expect(!code.contains("ComparisonSeed"), "\(file) names the comparison seed")
            #expect(!code.contains("ComparisonWindow"), "\(file) names the comparison window")
        }
        let window = try Self.code(Self.windowFile)
        #expect(window.contains("tab(for:"))
        for name in ["MenuBarStatusModel", "TabCloseWarning", "QuitSequence", "TabTeardown",
                     ".park(", ".claim(", ".register(", "unregister"] {
            #expect(!window.contains(name), "the window reaches \(name)")
        }
    }

    // MARK: Resolution

    /// The tab is found through the registry, the comparison through the tab,
    /// each in ONE place and in the resolving function — not in `body`, which
    /// SwiftUI runs whenever it likes. Re-resolving on a render would turn a
    /// finished comparison, which teardown has already removed from
    /// `tab.comparisons`, into "gone".
    @Test func theWindowResolvesOnceAndNotInItsBody() throws {
        let code = try Self.code(Self.windowFile)
        #expect(Self.occurrences(of: "registry.tab(for: seed.tabID)", in: code) == 1)
        #expect(Self.occurrences(of: ".comparison(id: seed.comparisonID)", in: code) == 1)
        // Both calls are inside `resolve(`, which latches.
        let resolve = try Self.body("func resolve(", in: Self.windowFile)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(resolve.contains("registry.tab(for: seed.tabID)"))
        #expect(resolve.contains(".comparison(id: seed.comparisonID)"))
        #expect(resolve.contains("guard !hasResolved else { return }"))

        // Negative, beside the positives above: nothing in the view's body
        // resolves, and the lookup names appear nowhere else in the file.
        let view = try Self.body("struct ComparisonWindow: View", in: Self.windowFile)
        #expect(!view.contains("tab(for:"))
        #expect(!view.contains("comparison(id:"))
        // The view asks the model to resolve, from `onAppear`.
        #expect(view.contains("model.resolve("))
        #expect(view.contains(".onAppear"))
    }

    @Test func sessionClosedIsKeyedOnTheReleasedFileSystemsNotOnTheResolution() throws {
        let model = try Self.body("final class ComparisonWindowModel", in: Self.windowFile)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Positive: the predicate exists and reads the comparison's own state.
        let start = try #require(model.range(of: "var isSessionClosed: Bool {"))
        // The predicate's own body: up to its second closing brace (the first
        // closes the `guard`).
        let predicate = model[start.upperBound...].components(separatedBy: "}").prefix(2)
            .joined(separator: "}")
        #expect(predicate.contains("comparison.fileSystems == nil"))
        // Negative: it is not derived from the resolution outcome.
        #expect(!predicate.contains("isUnavailable"))
        #expect(!predicate.contains("hasResolved"))
    }

    // MARK: Closing

    @Test func closingTheWindowCancelsThenReleasesAndIsDrivenByTheWindowsOwnClose() throws {
        let model = try Self.body("final class ComparisonWindowModel", in: Self.windowFile)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let start = try #require(model.range(of: "func windowClosed() {"))
        let body = String(model[start.upperBound...].prefix(300))
        let cancel = try #require(body.range(of: "comparison.cancel()"))
        let release = try #require(body.range(of: "comparison.releaseFileSystems()"))
        let forget = try #require(body.range(of: "forgetFromTab?()"))
        #expect(cancel.upperBound <= release.lowerBound)
        // The tab forgets last: the comparison is ended before it is dropped.
        #expect(release.upperBound <= forget.lowerBound)

        let code = try Self.code(Self.windowFile)
        #expect(Self.occurrences(of: "releaseFileSystems()", in: code) == 1)
        // The view calls it on THIS window's close and on no other.
        let view = try Self.body("struct ComparisonWindow: View", in: Self.windowFile)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(view.contains("NSWindow.willCloseNotification"))
        #expect(view.contains("closing === window"))
        #expect(view.contains("model.windowClosed()"))
        #expect(Self.occurrences(of: "model.windowClosed()", in: view) == 1)
    }

    /// The tab's removal of a comparison is spelled where it is declared and
    /// in the one window that closes, and nowhere else; and the model reaches
    /// the tab through a WEAK capture, never a stored reference.
    @Test func onlyTheClosingWindowMakesATabForgetAComparison() throws {
        var files: [String] = []
        for url in try SourceCorpus.files(under: Self.sources) where url.pathExtension == "swift" {
            if try SourceCorpus.code(of: url).contains("forgetComparison") {
                files.append(url.lastPathComponent)
            }
        }
        #expect(files.sorted() == ["ComparisonWindow.swift", "SessionTab.swift"])

        let tab = try Self.code("SessionTab.swift")
        #expect(tab.contains("func forgetComparison(id: UUID) { comparisons.removeAll { $0.id == id } }"))
        let window = try Self.code(Self.windowFile)
        #expect(window.contains("[weak tab] in tab?.forgetComparison(id: id)"))
        #expect(Self.occurrences(of: "forgetComparison", in: window) == 1)
    }

    // MARK: Ownership

    /// A stored property whose type is, or contains, a file system, a session,
    /// a connection or a queue: any identifier with one of those words in it
    /// (`ConnectionViewModel`, `SessionTab`, `Comparison.FileSystems`).
    private static let connectionType = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9_]*(FileSystem|Session|Connection|Connector|TransferQueue)[A-Za-z0-9_]*"#)

    private static func mentionsAConnection(_ declaration: String) -> Bool {
        connectionType.firstMatch(
            in: declaration, range: NSRange(declaration.startIndex..., in: declaration)) != nil
    }

    /// Top-level `let`/`var` declarations of a type body that are STORED, as
    /// whole lines. Attributes and modifiers before the keyword are allowed.
    /// A line is computed when its first `{` comes before any `=`.
    private static func storedProperties(in body: String) -> [String] {
        var depth = 0
        var found: [String] = []
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            defer {
                for character in line {
                    if character == "{" { depth += 1 }
                    if character == "}" { depth -= 1 }
                }
            }
            guard depth == 0 else { continue }
            let tokens = line.split(separator: " ")
            guard let keyword = tokens.firstIndex(where: { $0 == "let" || $0 == "var" }),
                tokens[..<keyword].allSatisfy({ token in
                    token.hasPrefix("@") || ["private", "fileprivate", "static", "nonisolated",
                                             "final", "weak", "lazy"].contains(String(token))
                        || token.hasPrefix("private(")
                })
            else { continue }
            let equals = line.firstIndex(of: "=")
            let brace = line.firstIndex(of: "{")
            if let brace, equals == nil || brace < equals! { continue }
            found.append(line)
        }
        return found
    }

    private static let typeDeclarations = [
        "struct ComparisonWindow: View",
        "final class ComparisonWindowModel",
        "struct ComparisonSeed: Codable, Hashable, Sendable",
    ]

    @Test func theWindowAndItsModelStoreNoFileSystemSessionOrConnection() throws {
        for declaration in Self.typeDeclarations {
            let properties = Self.storedProperties(
                in: try Self.body(declaration, in: Self.windowFile))
            #expect(!properties.isEmpty, "\(declaration) read as having no stored properties")
            for property in properties {
                #expect(
                    !Self.mentionsAConnection(property),
                    "\(declaration) stores a connection-typed property: \(property)")
            }
        }
    }

    /// Positive beside the scan above: what the window DOES hold is found by
    /// the same reader.
    @Test func theReaderFindsWhatTheWindowActuallyHolds() throws {
        let seed = Self.storedProperties(
            in: try Self.body(
                "struct ComparisonSeed: Codable, Hashable, Sendable", in: Self.windowFile))
        #expect(seed.count == 2)
        #expect(seed.contains { $0.contains("tabID: UUID") })
        #expect(seed.contains { $0.contains("comparisonID: UUID") })

        let window = Self.storedProperties(
            in: try Self.body("struct ComparisonWindow: View", in: Self.windowFile))
        #expect(window.contains { $0.contains("seed: ComparisonSeed") })
        #expect(window.contains { $0.contains("ComparisonWindowModel") })

        let model = Self.storedProperties(
            in: try Self.body("final class ComparisonWindowModel", in: Self.windowFile))
        #expect(model.contains { $0.contains("comparison: Comparison?") })
        #expect(model.contains { $0.contains("hasResolved") })
        #expect(model.contains { $0.contains("forgetFromTab") })
    }

    /// The pattern itself: it matches the spellings it forbids and none of
    /// the neighbouring names, and the reader tells stored from computed.
    @Test func theConnectionPatternAndTheReaderBehaveAsDescribed() {
        for forbidden in [
            "private var fs: any RemoteFileSystem", "var systems: Comparison.FileSystems?",
            "let local: LocalFileSystem", "var session: BrowserSession?",
            "var tab: SessionTab?", "var connection: ConnectionViewModel",
            "var queue: TransferQueueViewModel?",
        ] {
            #expect(Self.mentionsAConnection(forbidden), "\(forbidden) was not matched")
        }
        for allowed in [
            "let tabID: UUID", "private(set) var comparison: Comparison?",
            "let seed: ComparisonSeed", "@State private var window: NSWindow?",
            "@State private var model = ComparisonWindowModel()",
        ] {
            #expect(!Self.mentionsAConnection(allowed), "\(allowed) was matched")
        }

        let body = """
            let seed: ComparisonSeed
            @State private var model = ComparisonWindowModel()
            private let make: () -> Int = { 1 }
            var body: some View {
                let inner = RemoteFileSystemThing()
                Text("x")
            }
            var computed: Int { 3 }
            func f() { var local: BrowserSession? }
            """
        let found = Self.storedProperties(in: body)
        #expect(found.count == 3)
        #expect(found.contains("let seed: ComparisonSeed"))
        #expect(found.contains { $0.contains("make") })
        #expect(!found.contains { $0.contains("computed") })
        #expect(!found.contains { $0.contains("inner") })
    }

    // MARK: The seed

    @Test func theSeedCarriesIdentifiersOnly() throws {
        let properties = Self.storedProperties(
            in: try Self.body(
                "struct ComparisonSeed: Codable, Hashable, Sendable", in: Self.windowFile))
        #expect(properties.count == 2)
        for property in properties {
            #expect(property.hasSuffix(": UUID"), "the seed stores \(property), not a UUID")
        }
    }
}
