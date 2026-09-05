import Foundation
import Testing

/// Scans every `.swift` file under `Sources/` for calls to
/// `DiagnosticLog.shared.log(...)` and holds two properties of them: the
/// hard rule from the diagnostic-log design's "Never logged" paragraph
/// (NEGATIVE — no interpolation `\(…)` inside a call's arguments names an
/// identifier that looks like a secret), and, beside it, two POSITIVE
/// checks that keep the negative from going stale in silence the way
/// "Guards that name what they watch" describes: 27 call sites exist under
/// `Sources/` as of 2026-09-05 — `grep -c "DiagnosticLog.shared.log("` over
/// `Sources/`, counted the moment this suite was written (`docs/BACKLOG.md`
/// carries the same number). The assertion below holds the threshold at 20
/// rather than 27 itself, deliberately: it exists to catch a wholesale
/// regression (the scan losing its footing, or most of the instrumentation
/// being reverted), not to be re-edited on every call site a later task
/// adds or removes — see `noInterpolationNamesASecretIdentifier`'s own
/// assertion message for the up-to-date count if this ever goes red. Every
/// category literal used is also checked against the fixed eight the
/// diagnostic-log design settled on.
///
/// Scans `SwiftSource.stripComments`'s output, not
/// `stripCommentsAndStrings`'s: blanking string literals blanks what they
/// interpolate along with them (see that type's own doc comment), and an
/// interpolation's identifier is exactly what the negative check has to
/// read. Comments are blanked in both modes, so a commented-out call —
/// `// DiagnosticLog.shared.log(.debug, "sftp", "\(password)")` — neither
/// trips this guard nor satisfies it either way.
///
/// `DiagnosticLog.swift` — the sink's own file — is excluded from the scan,
/// not by matching its filename (a rename would silently stop excluding
/// it), but structurally: a file whose stripped text declares `final class
/// DiagnosticLog: Sendable`, the sink's own type, is skipped. In practice
/// that file never contains the literal spelling `DiagnosticLog.shared.log(`
/// at all — `log` is DEFINED there, not called on `.shared` — so the
/// exclusion is a belt-and-suspenders measure against exactly the situation
/// this project's other guards have been caught by: a doc comment or a
/// worked example inside that file spelling out what a call site looks
/// like.
@Suite("DiagnosticLog secrecy guard")
struct DiagnosticLogSecrecyGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPCoreTests/DiagnosticLogSecrecyGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let sourcesRoot = repoRoot.appendingPathComponent("Sources")

    /// Case-insensitive identifier fragments that must never appear inside
    /// a `DiagnosticLog.shared.log(...)` call's string interpolation — the
    /// design's "Never logged" paragraph, translated into a scan: no
    /// password, passphrase, private key, token, presigned URL, host key or
    /// fingerprint may reach the diagnostic log at any level. `secret` and
    /// `hostkey` are broader than any one field name on purpose — they also
    /// catch a future field this list was never updated for.
    private static let forbiddenFragments = [
        "password", "passphrase", "secret", "token", "privatekey",
        "presigned", "fingerprint", "hostkey",
    ]

    /// The fixed category list the diagnostic-log design settled on. A
    /// category outside this list is either a typo (a line nobody can
    /// filter on the way the design's other lines can) or an undocumented
    /// ninth category that needs a decision, not a silent addition.
    private static let fixedCategories: Set<String> = [
        "app", "browser.local", "browser.remote", "connect", "sftp",
        "shell", "transfer", "error",
    ]

    private struct CallSite {
        let file: String
        let arguments: String
    }

    private static func swiftFiles(under directory: URL) -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    private static let marker = "DiagnosticLog.shared.log("

    /// Every `DiagnosticLog.shared.log(...)` call site under `Sources/`,
    /// each with its brace-balanced argument text — comments blanked,
    /// string literals (and what they interpolate) intact.
    private static func collectCallSites() throws -> [CallSite] {
        var sites: [CallSite] = []
        for file in swiftFiles(under: sourcesRoot) {
            let raw = try String(contentsOf: file, encoding: .utf8)
            let stripped = try SwiftSource.stripComments(raw)
            guard !stripped.contains("final class DiagnosticLog: Sendable") else { continue }
            sites.append(contentsOf: Self.callSites(in: stripped, file: file.lastPathComponent))
        }
        return sites
    }

    /// Finds every occurrence of `marker` in `text` and extracts the
    /// argument list that follows as brace-balanced text: paren depth is
    /// counted over the WHOLE span (string-literal content included), which
    /// is sound for every call this project writes because none of them put
    /// a lone, unmatched `(` or `)` character in a category or message
    /// literal outside of a `\(...)` interpolation's own (already-balanced)
    /// parens.
    private static func callSites(in text: String, file: String) -> [CallSite] {
        var results: [CallSite] = []
        let chars = Array(text)
        var searchFrom = text.startIndex
        while let range = text.range(of: marker, range: searchFrom..<text.endIndex) {
            var i = text.distance(from: text.startIndex, to: range.upperBound)
            let argStart = i
            var depth = 1
            while i < chars.count, depth > 0 {
                switch chars[i] {
                case "(": depth += 1
                case ")": depth -= 1
                default: break
                }
                i += 1
            }
            guard depth == 0 else {
                // Unterminated call — nothing this project writes should
                // ever reach here; stop rather than guess.
                break
            }
            let argEnd = i - 1
            results.append(CallSite(file: file, arguments: String(chars[argStart..<argEnd])))
            searchFrom = text.index(text.startIndex, offsetBy: i)
        }
        return results
    }

    /// The text inside every `\(...)` in `arguments`, brace-balanced the
    /// same way `callSites(in:file:)` balances a call's own argument list —
    /// an interpolation can itself contain a nested call with its own
    /// parens (`\(Int(ms))`).
    private static func interpolations(in arguments: String) -> [String] {
        var results: [String] = []
        let chars = Array(arguments)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count, chars[i + 1] == "(" {
                var depth = 1
                var j = i + 2
                let start = j
                while j < chars.count, depth > 0 {
                    if chars[j] == "(" { depth += 1 }
                    if chars[j] == ")" { depth -= 1 }
                    j += 1
                }
                let end = max(start, j - 1)
                results.append(String(chars[start..<end]))
                i = j
            } else {
                i += 1
            }
        }
        return results
    }

    /// Splits `arguments` on commas at PAREN depth 0 and outside string
    /// literals — enough to isolate the second positional argument (the
    /// category), which is all this project's own call sites ever need:
    /// none puts a raw comma inside the level or category text.
    private static func topLevelCommaSplit(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inString = false
        for c in text {
            if c == "\"" { inString.toggle() }
            if !inString {
                if c == "(" { depth += 1 }
                if c == ")" { depth -= 1 }
                if c == ",", depth == 0 {
                    parts.append(current)
                    current = ""
                    continue
                }
            }
            current.append(c)
        }
        parts.append(current)
        return parts
    }

    /// The second positional argument's literal text, un-blanked (every
    /// call site in this project writes `.log(<level>, "<category>",
    /// <message>)`) — `nil` if it is not a plain string literal.
    private static func categoryLiteral(in arguments: String) -> String? {
        let parts = Self.topLevelCommaSplit(arguments)
        guard parts.count >= 2 else { return nil }
        let candidate = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.hasPrefix("\""), candidate.hasSuffix("\""), candidate.count >= 2 else {
            return nil
        }
        return String(candidate.dropFirst().dropLast())
    }

    /// The second positional argument's raw text (un-blanked, whitespace-
    /// trimmed) when it is NOT a plain string literal — `nil` when it is
    /// one (that case is `categoryLiteral`'s). `RemoteBrowserViewModel`'s
    /// two call sites pass `logCategory`, a stored property rather than a
    /// literal, since the view model doesn't know at compile time which
    /// pane it's bound to (see that property's own doc comment) — this is
    /// what lets `everyCategoryLiteralIsOnTheFixedList` recognize that one
    /// dynamic case instead of just failing on it.
    private static func categoryIdentifier(in arguments: String) -> String? {
        let parts = Self.topLevelCommaSplit(arguments)
        guard parts.count >= 2 else { return nil }
        let candidate = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(candidate.hasPrefix("\"") && candidate.hasSuffix("\"")) else { return nil }
        return candidate
    }

    /// Every STRING LITERAL value a dynamic category identifier can hold —
    /// resolved structurally rather than assumed, by scanning `Sources/`
    /// for `<identifier>: "..."` (a labeled argument, or a defaulted
    /// parameter once `String =` is skipped over) and `<identifier> =
    /// "..."` (a plain assignment). Both patterns bound the gap between the
    /// identifier and its delimiter to `[ \t]*` and the captured literal to
    /// `[^"\n]*` — same-line only — so a property declared with no default
    /// on one line (`public let logCategory: String`) cannot have its `:`
    /// pair up with an unrelated quote several lines later. Fails closed
    /// the same way `collectCallSites()` does: an identifier with no
    /// literal assignment found anywhere returns an empty set, which the
    /// caller then has to treat as unresolved rather than silently "fine".
    private static func literalValues(assignedTo identifier: String) throws -> Set<String> {
        var values: Set<String> = []
        for file in swiftFiles(under: sourcesRoot) {
            let raw = try String(contentsOf: file, encoding: .utf8)
            let stripped = try SwiftSource.stripComments(raw)
            values.formUnion(try Self.literalValues(assignedTo: identifier, in: stripped))
        }
        return values
    }

    /// The pure half of `literalValues(assignedTo:)` above — over already-
    /// comments-stripped text, so a self-test can exercise the two regexes
    /// directly without touching the file system.
    private static func literalValues(assignedTo identifier: String, in strippedText: String) throws
        -> Set<String>
    {
        let patterns = [
            #"\#(identifier)[ \t]*:[ \t]*(?:String[ \t]*=[ \t]*)?"([^"\n]*)""#,
            #"\#(identifier)[ \t]*=[ \t]*"([^"\n]*)""#,
        ]
        var values: Set<String> = []
        let range = NSRange(strippedText.startIndex..., in: strippedText)
        for pattern in patterns {
            let regex = try NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: strippedText, range: range) {
                guard let valueRange = Range(match.range(at: 1), in: strippedText) else { continue }
                values.insert(String(strippedText[valueRange]))
            }
        }
        return values
    }

    /// The hard rule: no interpolation inside any call site's arguments
    /// names a secret-shaped identifier. Beside it, the positive that keeps
    /// this from being a check that passes by finding nothing to look at —
    /// the call-site count itself, which any refactor that broke the
    /// `marker` string, the file walk, or the brace counter would also
    /// drive toward zero.
    @Test func noInterpolationNamesASecretIdentifier() throws {
        let sites = try Self.collectCallSites()
        #expect(
            sites.count >= 20,
            """
            only \(sites.count) DiagnosticLog.shared.log( call sites found under Sources/ — \
            the scan is not reaching the files it is meant to guard, or the instrumentation \
            this task added regressed.
            """)

        var offenders: [String] = []
        for site in sites {
            for interpolation in Self.interpolations(in: site.arguments) {
                let lowered = interpolation.lowercased()
                for fragment in Self.forbiddenFragments where lowered.contains(fragment) {
                    offenders.append("\(site.file): \\(\(interpolation))")
                }
            }
        }
        #expect(
            offenders.isEmpty,
            """
            a DiagnosticLog.shared.log(...) call interpolates something that looks like a \
            secret:
            \(offenders.joined(separator: "\n"))

            The design's "Never logged" paragraph is a hard rule: no password, passphrase, \
            private key, token, presigned URL, host key or fingerprint may reach the \
            diagnostic log at any level.
            """)
    }

    /// The second positive: every category used is one of the fixed eight —
    /// a literal checked directly, or, for the one call site that passes a
    /// variable (`RemoteBrowserViewModel`'s `logCategory`, set by the App
    /// per pane rather than known at the call site itself), every literal
    /// that identifier could structurally hold, checked the same way. A
    /// category is data a reader filters the log file by (`grep "] connect
    /// "`), so a typo or an ad-hoc ninth category is a line nobody can find
    /// that way.
    @Test func everyCategoryLiteralIsOnTheFixedList() throws {
        let sites = try Self.collectCallSites()
        var offenders: [String] = []
        var resolvedIdentifiers: Set<String> = []
        for site in sites {
            if let category = Self.categoryLiteral(in: site.arguments) {
                if !Self.fixedCategories.contains(category) {
                    offenders.append(
                        "\(site.file): category \"\(category)\" is not one of \(Self.fixedCategories.sorted())"
                    )
                }
                continue
            }
            guard let identifier = Self.categoryIdentifier(in: site.arguments) else {
                offenders.append(
                    "\(site.file): no category argument found in (\(site.arguments))")
                continue
            }
            // Resolve (and check) each distinct identifier once, however
            // many call sites pass it.
            guard resolvedIdentifiers.insert(identifier).inserted else { continue }
            let values = try Self.literalValues(assignedTo: identifier)
            if values.isEmpty {
                offenders.append(
                    "\(site.file): category argument \"\(identifier)\" is a variable, and no "
                        + "string-literal value assigned to it was found anywhere under Sources/"
                )
            }
            for value in values where !Self.fixedCategories.contains(value) {
                offenders.append(
                    "\(identifier) can hold \"\(value)\", which is not one of "
                        + "\(Self.fixedCategories.sorted())"
                )
            }
        }
        #expect(offenders.isEmpty, "\(offenders.joined(separator: "\n"))")
    }

    /// Whether a call site's arguments use the `reason:` labeled overload
    /// (`DiagnosticLog.log(_:_:_:reason:)`) — a top-level argument (outside
    /// any string literal or nested call) whose trimmed text starts with
    /// `reason:` (colon). That label is the ONLY spelling of the word
    /// `reason` this project's calls may write; the formatted key
    /// (`reason=`, equals sign) is appended by the overload itself, never
    /// typed by a caller — see `noHandWrittenMessageSpellsReasonEquals`,
    /// this check's negative counterpart.
    private static func usesReasonOverload(_ arguments: String) -> Bool {
        Self.topLevelCommaSplit(arguments).contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("reason:")
        }
    }

    /// The structural fix (diagnostic-log plan, Task 3 fix round 1,
    /// Critical/Important/Structural findings): a regex over category
    /// spellings cannot tell a safe `reason=\(DialSupport.reason(for:
    /// error))` from an unsafe `reason=\(error)` or `reason=\(message)` —
    /// both are "a call whose category is on the fixed list, with no
    /// forbidden identifier interpolated," which is everything the two
    /// checks above ask. So this project no longer writes `reason=` by
    /// hand at all: `DiagnosticLog.log(_:_:_:reason:)` is the one place
    /// that key is formatted, and it always builds the value through
    /// `DialSupport.reason(for:)`. NEGATIVE: no call's arguments contain
    /// the literal text `reason=` (an equals sign) anywhere — that
    /// substring can only appear if a caller typed it into the message
    /// argument by hand, since the label callers DO write is `reason:`
    /// (a colon, checked separately by `usesReasonOverload`, never
    /// confused with this one because `=` and `:` are different
    /// characters). POSITIVE beside it: at least 3 call sites use the
    /// `reason:` overload — 7 measured 2026-09-05 (`LocalFileSystem.list`,
    /// `RemoteBrowserViewModel.load`, `ConnectionViewModel.connect`
    /// (`connect failed`), `CitadelFileSystem`'s `measured` helper,
    /// `CitadelShell.open`, `TransferEngine.copyFile`,
    /// `BrowserPane`'s App-layer `error` line) — matching
    /// `docs/BACKLOG.md`'s row.
    @Test func noHandWrittenMessageSpellsReasonEquals() throws {
        let sites = try Self.collectCallSites()
        let offenders = sites.filter { $0.arguments.contains("reason=") }
            .map { "\($0.file): \($0.arguments)" }
        #expect(
            offenders.isEmpty,
            """
            a DiagnosticLog.shared.log(...) call spells `reason=` by hand instead of using \
            the `reason:` overload, which builds that key itself through \
            `DialSupport.reason(for:)`:
            \(offenders.joined(separator: "\n"))
            """)

        let reasonOverloadSites = sites.filter { Self.usesReasonOverload($0.arguments) }
        #expect(
            reasonOverloadSites.count >= 3,
            """
            only \(reasonOverloadSites.count) call sites use the `reason:` overload — the scan \
            is not reaching them, or the conversion this fix round made regressed.
            """)
    }

    // MARK: - Self-tests

    /// `literalValues(assignedTo:in:)`'s own correctness: a defaulted typed
    /// parameter, a labeled call-site argument, and a plain assignment are
    /// all found; a same-named identifier that is never assigned a literal
    /// anywhere (only read, or assigned another variable) contributes
    /// nothing.
    @Test func selfTestDynamicCategoryResolution() throws {
        let stripped = try SwiftSource.stripComments(
            """
            struct S {
                let logCategory: String
                init(logCategory: String = "browser.remote") { self.logCategory = logCategory }
            }
            let a = S(logCategory: "browser.local")
            let b = S()
            var mirrored = "unused"
            mirrored = logCategory
            """)
        let values = try Self.literalValues(assignedTo: "logCategory", in: stripped)
        #expect(values == ["browser.remote", "browser.local"])
    }

    /// The extractor's own correctness, over text this test writes rather
    /// than the real tree — proves the scan actually finds a violation
    /// before trusting it to find none in `Sources/`.
    @Test func selfTestFindsAPlantedSecretInterpolation() throws {
        let stripped = try SwiftSource.stripComments(
            """
            DiagnosticLog.shared.log(.debug, "sftp", "auth ok")
            DiagnosticLog.shared.log(.debug, "sftp", "leak \\(password) here")
            // DiagnosticLog.shared.log(.debug, "sftp", "\\(password)")
            """)
        let sites = Self.callSites(in: stripped, file: "planted.swift")
        #expect(sites.count == 2, "the commented-out call must not be found: \(sites)")
        let offenders = sites.flatMap { site in
            Self.interpolations(in: site.arguments).filter {
                $0.lowercased().contains("password")
            }
        }
        #expect(offenders == ["password"])
    }

    /// The category extractor's own correctness: a literal on the fixed
    /// list passes, one that is not gets named.
    @Test func selfTestCategoryExtraction() throws {
        let stripped = try SwiftSource.stripComments(
            """
            DiagnosticLog.shared.log(.info, "browser.local", "list done path=/x count=1 ms=2")
            DiagnosticLog.shared.log(.info, "made.up.category", "oops")
            """)
        let sites = Self.callSites(in: stripped, file: "planted.swift")
        #expect(sites.count == 2)
        #expect(Self.categoryLiteral(in: sites[0].arguments) == "browser.local")
        #expect(Self.categoryLiteral(in: sites[1].arguments) == "made.up.category")
        #expect(!Self.fixedCategories.contains(Self.categoryLiteral(in: sites[1].arguments) ?? ""))
    }

    /// `usesReasonOverload`'s own correctness, and the negative it backs:
    /// a call using the `reason:` label is recognized as such and carries
    /// no literal `reason=`; a call that still hand-formats `reason=` is
    /// caught by the OTHER half of `noHandWrittenMessageSpellsReasonEquals`
    /// regardless of what it's labeled.
    @Test func selfTestReasonOverloadDetection() throws {
        let stripped = try SwiftSource.stripComments(
            """
            DiagnosticLog.shared.log(.debug, "sftp", "op failed", reason: error)
            DiagnosticLog.shared.log(.debug, "sftp", "op failed reason=\\(error)")
            """)
        let sites = Self.callSites(in: stripped, file: "planted.swift")
        #expect(sites.count == 2)
        #expect(Self.usesReasonOverload(sites[0].arguments))
        #expect(!sites[0].arguments.contains("reason="))
        #expect(!Self.usesReasonOverload(sites[1].arguments))
        #expect(sites[1].arguments.contains("reason="))
    }
}
