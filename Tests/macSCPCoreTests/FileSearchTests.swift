import Foundation
import Testing
@testable import macSCPCore

/// Pure matcher/derivation tests (M11k/T1) — no view model, no file system.
@Suite("FileSearch")
struct FileSearchTests {
    // MARK: - compile

    @Test func emptyQueryMatchesEverything() {
        let result = FileSearch.compile(query: "", isRegex: false)
        guard case .success(let predicate) = result else {
            Issue.record("expected a predicate for an empty query")
            return
        }
        #expect(predicate.isEmpty)
        #expect(predicate.matches("anything.txt"))
        #expect(predicate.matches(""))
    }

    @Test func blankQueryMatchesEverything() {
        // Whitespace-only is treated the same as empty — "no filter", not a
        // literal-space substring search.
        let result = FileSearch.compile(query: "   ", isRegex: false)
        guard case .success(let predicate) = result else {
            Issue.record("expected a predicate for a blank query")
            return
        }
        #expect(predicate.isEmpty)
        #expect(predicate.matches("anything.txt"))
    }

    @Test func substringMatchIsCaseInsensitive() {
        let result = FileSearch.compile(query: "log", isRegex: false)
        guard case .success(let predicate) = result else {
            Issue.record("expected a predicate")
            return
        }
        #expect(!predicate.isEmpty)
        #expect(predicate.matches("Access.LOG"))
        #expect(!predicate.matches("readme"))
    }

    @Test func validRegexMatchesAnchoredPattern() {
        let result = FileSearch.compile(query: "\\.log$", isRegex: true)
        guard case .success(let predicate) = result else {
            Issue.record("expected a compiled regex predicate")
            return
        }
        #expect(predicate.matches("a.log"))
        #expect(!predicate.matches("a.log.1"))
    }

    @Test func validRegexHonorsCaretAnchor() {
        let result = FileSearch.compile(query: "^var", isRegex: true)
        guard case .success(let predicate) = result else {
            Issue.record("expected a compiled regex predicate")
            return
        }
        #expect(predicate.matches("varlog"))
        #expect(!predicate.matches("avar"))
    }

    @Test func regexMatchIsCaseInsensitive() {
        let result = FileSearch.compile(query: "^VAR", isRegex: true)
        guard case .success(let predicate) = result else {
            Issue.record("expected a compiled regex predicate")
            return
        }
        #expect(predicate.matches("varlog"))
    }

    @Test func invalidRegexIsItsOwnFailure() {
        let result = FileSearch.compile(query: "[", isRegex: true)
        guard case .failure(let error) = result else {
            Issue.record("expected an invalid-regex failure, got a compiled predicate")
            return
        }
        #expect(error == .invalidRegex)
    }

    /// `localizedCaseInsensitiveContains` is Unicode/diacritic-aware via
    /// `NSString` comparison rules: a plain "u" query does NOT match "ü"
    /// (they are different base characters), but a differently-cased
    /// precomposed match ("müller" vs "Müller") does. This test documents
    /// that behavior rather than asserting looser diacritic folding, which
    /// `localizedCaseInsensitiveContains` does not perform.
    @Test func unicodeUmlautMatchesCaseInsensitively() {
        let result = FileSearch.compile(query: "müller", isRegex: false)
        guard case .success(let predicate) = result else {
            Issue.record("expected a predicate")
            return
        }
        #expect(predicate.matches("Müller.txt"))
        #expect(!predicate.matches("Muller.txt"))   // no diacritic folding
    }

    // MARK: - derive (filter mode)

    private func items(_ names: [String]) -> [RemoteFileItem] {
        names.map { RemoteFileItem(name: $0, path: "/\($0)", kind: .file, size: 1) }
    }

    @Test func deriveFilterModeReturnsOnlyMatches() {
        let all = items(["Access.log", "readme.md", "error.log"])
        let result = FileSearch.derive(all: all, query: "log", isRegex: false, mode: .filter)
        guard case .success(let derivation) = result else {
            Issue.record("expected a successful derivation")
            return
        }
        #expect(derivation.visible.map(\.name) == ["Access.log", "error.log"])
        #expect(derivation.matchCount == 2)
        #expect(derivation.totalCount == 3)
    }

    @Test func deriveFilterModeWithEmptyQueryShowsEverything() {
        let all = items(["a.txt", "b.txt"])
        let result = FileSearch.derive(all: all, query: "", isRegex: false, mode: .filter)
        guard case .success(let derivation) = result else {
            Issue.record("expected a successful derivation")
            return
        }
        #expect(derivation.visible.map(\.name) == ["a.txt", "b.txt"])
        #expect(derivation.matchCount == 2)
        #expect(derivation.totalCount == 2)
    }

    // MARK: - derive (jump mode)

    @Test func deriveJumpModeKeepsFullListAndReportsMatchPaths() {
        let all = items(["Access.log", "readme.md", "error.log"])
        let result = FileSearch.derive(all: all, query: "log", isRegex: false, mode: .jump)
        guard case .success(let derivation) = result else {
            Issue.record("expected a successful derivation")
            return
        }
        #expect(derivation.visible.map(\.name) == ["Access.log", "readme.md", "error.log"])
        #expect(derivation.matchPaths == ["/Access.log", "/error.log"])
        #expect(derivation.matchCount == 2)
        #expect(derivation.totalCount == 3)
    }

    // MARK: - derive (invalid regex)

    @Test func deriveWithInvalidRegexFails() {
        let all = items(["a.txt"])
        let result = FileSearch.derive(all: all, query: "[", isRegex: true, mode: .filter)
        #expect(result == .failure(.invalidRegex))
    }
}
