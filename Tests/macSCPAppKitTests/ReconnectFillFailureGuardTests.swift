import Foundation
import MacSCPTestSupport
import Testing

/// Guards what an in-place connect shows when the stored-session fill THROWS
/// (technical backlog of 2026-09-16, Task 5).
///
/// `ContentView.fillForm(_:from:)` is declared `throws`: it catches
/// `LoginResolveError` itself — a dangling login set is a REFUSAL, published
/// on the form, and returns `false` — and lets anything else out.
/// `connect(in:stored:paneVisibility:)` used to run that fill in a discarded
/// throwing `Task`, so such a throw ended the attempt with nothing on screen.
/// The sidebar's "Open in External Terminal" route, which runs the very same
/// fill, already caught it and showed `error.localizedDescription`.
///
/// Scanned rather than run: no fill this project can drive throws anything
/// but `LoginResolveError` today (every resolver it calls reads the Keychain
/// through `try?`), so there is no fixture that reaches the catch. What is
/// pinned instead is the shape, and one half of it is a compiler boundary:
///
/// 1. The connect's task is a `Task<Void, Never>` — a `try` left uncaught
///    inside it does not compile, so the throw cannot escape again.
/// 2. Its one `fillForm(` call sits inside a `do` whose `catch` publishes on
///    the form (`showFailure(`) the text the sidebar route shows,
///    `error.localizedDescription` — and the sidebar route still shows that
///    text in its own `catch`, so the two cannot drift apart unnoticed.
///
/// Every read goes through `SwiftSource.blankingCommentsAndStrings`, so a
/// comment quoting either shape satisfies nothing. Every check requires
/// something present; the scanner self-tests below run it against the old
/// shape and against three violations.
@Suite("Reconnect fill-failure guard")
struct ReconnectFillFailureGuardTests {
    private static let contentViewFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView.swift")

    private enum ScanError: Error { case anchorNotFound, openBraceNotFound, unbalancedBraces }

    /// The text both routes show for a fill that threw, as code.
    private static let failureText = "error.localizedDescription"

    @Test func anInPlaceConnectShowsAFillThatThrew() throws {
        let source = try SourceCorpus.text(of: Self.contentViewFile)
        let violations = try Self.violations(inSource: source)
        #expect(violations.isEmpty, """
            `connect(in:stored:paneVisibility:)` does not show a fill that threw the way the \
            sidebar's external-terminal route does: \(violations)
            """)
    }

    // MARK: - Scanner self-tests

    private static func fixture(connectTask: String, sidebarCatch: String = failureText) -> String {
        """
        struct ContentView {
            func connect(
                in tab: SessionTab, stored: StoredSession, paneVisibility: PaneVisibility? = nil
            ) {
                guard !tab.isReconnecting else { return }
                \(connectTask)
            }

            func openExternalTerminalFromSidebar(_ stored: StoredSession) {
                do {
                    guard try fillForm(form, from: stored) else { return }
                } catch {
                    externalTerminalErrorMessage = \(sidebarCatch)
                    return
                }
            }
        }
        """
    }

    private static let fixedTask = """
        Task<Void, Never> {
            let form = tab.connectionViewModel
            do {
                guard try fillForm(form, from: stored) else { return }
            } catch {
                form.showFailure(message: error.localizedDescription)
                return
            }
            if let fs = await form.connect(origin: stored.id) { use(fs) }
        }
        """

    @Test func theScannerAcceptsTheFixedShape() throws {
        #expect(try Self.violations(inSource: Self.fixture(connectTask: Self.fixedTask)).isEmpty)
    }

    @Test("the old shape and its near misses are reported", arguments: [
        // The shape before Task 5: a throwing task nobody awaits.
        """
        _ = Task {
            let form = tab.connectionViewModel
            guard try fillForm(form, from: stored) else { return }
        }
        """,
        // Caught, but shown nowhere.
        """
        Task<Void, Never> {
            let form = tab.connectionViewModel
            do {
                guard try fillForm(form, from: stored) else { return }
            } catch {
                return
            }
        }
        """,
        // Shown, but in other words than the sidebar's.
        """
        Task<Void, Never> {
            let form = tab.connectionViewModel
            do {
                guard try fillForm(form, from: stored) else { return }
            } catch {
                form.showFailure(message: fallbackText)
                return
            }
        }
        """,
    ])
    func theScannerReportsAnUnshownThrow(connectTask: String) throws {
        let violations = try Self.violations(inSource: Self.fixture(connectTask: connectTask))
        #expect(violations.isEmpty == false, "the scanner accepted:\n\(connectTask)")
    }

    @Test func theScannerSeesTheSidebarDrifting() throws {
        let violations = try Self.violations(
            inSource: Self.fixture(connectTask: Self.fixedTask, sidebarCatch: "otherText"))
        #expect(violations.isEmpty == false)
    }

    @Test func theScannerFailsClosedOnAMissingAnchor() {
        #expect(throws: ScanError.self) {
            try Self.violations(inSource: "struct ContentView {}")
        }
    }

    // MARK: - Scanner

    /// What is wrong, as sentences — empty when both claims in the header
    /// hold. Throws when a function it names is not there at all.
    private static func violations(inSource source: String) throws -> [String] {
        let blanked = try SwiftSource.blankingCommentsAndStrings(source)
        var violations: [String] = []

        let connect = try body(ofFunctionWhoseSignatureContains: "stored: StoredSession, paneVisibility:",
                               named: "func connect(", in: blanked)
        let fillsInConnect = occurrences(of: "fillForm(", in: connect)
        if fillsInConnect != 1 {
            violations.append("`fillForm(` is called \(fillsInConnect) times in the connect, not once")
        }
        if let taskOpen = connect.range(of: "Task<Void, Never>"),
           let brace = connect[taskOpen.upperBound...].firstIndex(of: "{") {
            let task = try balancedSpan(from: brace, in: connect)
            if let caught = catchSpan(guardingFirst: "fillForm(", in: task) {
                if !caught.contains("showFailure(") {
                    violations.append("the fill's `catch` publishes nothing on the form (`showFailure(`)")
                }
                if !caught.contains(failureText) {
                    violations.append("the fill's `catch` does not show `\(failureText)`")
                }
            } else {
                violations.append("the connect's `fillForm(` is not inside a `do` with a `catch`")
            }
        } else {
            violations.append("the connect's task is not a `Task<Void, Never>`, so a throw can escape it")
        }

        let sidebar = try body(ofFunctionWhoseSignatureContains: "", named: "func openExternalTerminalFromSidebar(", in: blanked)
        if let caught = catchSpan(guardingFirst: "fillForm(", in: sidebar) {
            if !caught.contains(failureText) {
                violations.append("the sidebar route's `catch` no longer shows `\(failureText)`")
            }
        } else {
            violations.append("the sidebar route's `fillForm(` is not inside a `do` with a `catch`")
        }
        return violations
    }

    /// The `catch` block of the first `do` whose block contains `token`, or
    /// `nil` when there is none.
    private static func catchSpan(guardingFirst token: String, in source: String) -> String? {
        var searchStart = source.startIndex
        while let keyword = source.range(of: "do", range: searchStart..<source.endIndex) {
            searchStart = keyword.upperBound
            guard isWholeWord(keyword, in: source),
                  let brace = source[keyword.upperBound...].firstIndex(where: { !$0.isWhitespace }),
                  source[brace] == "{",
                  let block = try? balancedSpan(from: brace, in: source),
                  block.contains(token)
            else { continue }
            let afterBlock = source.index(brace, offsetBy: block.count)
            let rest = source[afterBlock...]
            guard let catchKeyword = rest.range(of: "catch"),
                  rest[rest.startIndex..<catchKeyword.lowerBound].allSatisfy(\.isWhitespace),
                  let catchBrace = rest[catchKeyword.upperBound...].firstIndex(of: "{")
            else { return nil }
            return try? balancedSpan(from: catchBrace, in: source)
        }
        return nil
    }

    private static func body(
        ofFunctionWhoseSignatureContains marker: String, named anchor: String, in blanked: String
    ) throws -> String {
        var searchStart = blanked.startIndex
        while let found = blanked.range(of: anchor, range: searchStart..<blanked.endIndex) {
            searchStart = found.upperBound
            guard let brace = blanked[found.upperBound...].firstIndex(of: "{") else {
                throw ScanError.openBraceNotFound
            }
            let signature = blanked[found.upperBound..<brace]
            guard marker.isEmpty || removingWhitespace(String(signature))
                .contains(removingWhitespace(marker))
            else { continue }
            return try balancedSpan(from: brace, in: blanked)
        }
        throw ScanError.anchorNotFound
    }

    private static func balancedSpan(from openBrace: String.Index, in source: String) throws -> String {
        var depth = 0
        var index = openBrace
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[openBrace...index]) }
            }
            index = source.index(after: index)
        }
        throw ScanError.unbalancedBraces
    }

    private static func isWholeWord(_ range: Range<String.Index>, in source: String) -> Bool {
        let before = range.lowerBound == source.startIndex
            || !isIdentifierCharacter(source[source.index(before: range.lowerBound)])
        let after = range.upperBound == source.endIndex
            || !isIdentifierCharacter(source[range.upperBound])
        return before && after
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func removingWhitespace(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }

    private static func occurrences(of token: String, in source: String) -> Int {
        source.components(separatedBy: token).count - 1
    }
}
