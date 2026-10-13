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
        // The predicate's own body, by brace matching.
        let predicate = try Self.body("var isSessionClosed: Bool", in: Self.windowFile)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Positive: it exists and reads the comparison's own state.
        #expect(predicate.contains("comparison.fileSystems == nil"))
        // Negative: it is not derived from the resolution outcome.
        #expect(!predicate.contains("isUnavailable"))
        #expect(!predicate.contains("hasResolved"))
    }

    // MARK: Closing

    @Test func closingTheWindowCancelsThenReleasesAndIsDrivenByTheWindowsOwnClose() throws {
        // The function's own body, by brace matching: a comment or another
        // statement added to it cannot push a call out of range.
        let body = try Self.body("func windowClosed()", in: Self.windowFile)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
        // Positive beside the comparison above. `closing === window` is only
        // as good as `window` having a value: with no accessor attached to
        // the view it stays nil for ever, the comparison is never true and the
        // close path never runs, with every other check here still green.
        // So the accessor is attached, and its callback assigns `window`.
        let attached = view.replacingOccurrences(of: "( ", with: "(")
        #expect(attached.contains(".background(WindowAccessor {"))
        #expect(attached.contains("window = resolved"))
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
    /// (`ConnectionViewModel`, `SessionTab`, `Comparison.FileSystems`) — or the
    /// registry, a window id or a bare tab, each of which is a way to reach
    /// every tab and so every session in the process.
    ///
    /// This is a list of names somebody thought of, and it is the SECOND line
    /// of defence: `allowedShapes` below is the first, and it is a list of
    /// what is permitted, so a type nobody thought of fails by default.
    private static let connectionType = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9_]*(FileSystem|Session|Connection|Connector|TransferQueue|TabRegistry|WindowID)[A-Za-z0-9_]*|(?<![A-Za-z0-9_])Tab(?![A-Za-z0-9_])"#)

    /// Everything the window, its model and its seed may store, as the TYPE
    /// (or, where a property is declared without one, its initial value).
    /// Anything else — a registry, a tab, a file system, a type nobody has
    /// thought of — fails until somebody decides here that it is fine.
    private static let allowedShapes: Set<String> = [
        // The seed.
        "UUID",
        // The view.
        "ComparisonSeed", "ComparisonWindowModel()", "NSWindow?",
        // The model: the comparison it holds, its latch, and the weak
        // closure through which it asks the tab to forget it.
        "Comparison?", "false", "(@MainActor () -> Void)?",
    ]

    /// The part of a stored-property line after its name: the declared type,
    /// or, with none, the initial value.
    private static func shape(of line: String) -> String? {
        var tokens = line.split(separator: " ").map(String.init)
        guard let keyword = tokens.firstIndex(where: { $0 == "let" || $0 == "var" }) else {
            return nil
        }
        tokens.removeFirst(keyword + 1)
        let rest = tokens.joined(separator: " ")
        // A declared type comes before any `=`; without one, a `:` further on
        // belongs to the initial value (`[String: Data]()`).
        let equalsIndex = rest.firstIndex(of: "=")
        if let colon = rest.firstIndex(of: ":"), equalsIndex == nil || colon < equalsIndex! {
            var type = String(rest[rest.index(after: colon)...])
            if let equals = type.firstIndex(of: "=") { type = String(type[..<equals]) }
            return type.trimmingCharacters(in: .whitespaces)
        }
        guard let equals = equalsIndex else { return nil }
        return String(rest[rest.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
    }

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

    /// The strong form: not "nothing on a list of bad names" but "only what is
    /// on a list of good ones". The model storing `TabRegistry` was a hole in
    /// the first form that no name on its list covered.
    @Test func everythingTheWindowStoresIsOfAShapeTheOwnershipRuleAllows() throws {
        for declaration in Self.typeDeclarations {
            let properties = Self.storedProperties(
                in: try Self.body(declaration, in: Self.windowFile))
            #expect(!properties.isEmpty, "\(declaration) read as having no stored properties")
            for property in properties {
                let shape = Self.shape(of: property)
                #expect(shape != nil, "\(declaration): no type or value read from: \(property)")
                #expect(
                    shape.map { Self.allowedShapes.contains($0) } == true,
                    "\(declaration) stores a shape the ownership rule has not allowed: \(property)")
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
            "private var registry: TabRegistry = .shared", "var registry: TabRegistry?",
            "let home: WindowID", "var tab: Tab?",
        ] {
            #expect(Self.mentionsAConnection(forbidden), "\(forbidden) was not matched")
        }
        for allowed in [
            "let tabID: UUID", "private(set) var comparison: Comparison?",
            "let seed: ComparisonSeed", "@State private var window: NSWindow?",
            "@State private var model = ComparisonWindowModel()",
            "var tabID: UUID", "let tabs: [Int]", "var table: Int",
        ] {
            #expect(!Self.mentionsAConnection(allowed), "\(allowed) was matched")
        }

        // The shape reader, and the allowed list it feeds: a type nobody
        // listed is refused by default, a type somebody did is not.
        #expect(Self.shape(of: "let tabID: UUID") == "UUID")
        #expect(Self.shape(of: "@State private var model = ComparisonWindowModel()")
            == "ComparisonWindowModel()")
        #expect(Self.shape(of: "private(set) var hasResolved = false") == "false")
        #expect(Self.shape(of: "private var registry: TabRegistry = .shared") == "TabRegistry")
        #expect(Self.allowedShapes.contains("UUID"))
        for refused in [
            "private var registry: TabRegistry = .shared", "var tab: Tab?",
            "var clock: ContinuousClock", "var cache = [String: Data]()",
        ] {
            let shape = Self.shape(of: refused)
            #expect(shape != nil)
            #expect(shape.map { Self.allowedShapes.contains($0) } == false, "\(refused) was allowed")
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
