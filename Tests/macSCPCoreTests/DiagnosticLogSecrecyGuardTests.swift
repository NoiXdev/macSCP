import Foundation
import MacSCPTestSupport
import Testing

/// Scans every `.swift` file under `Sources/` for calls to
/// `DiagnosticLog.shared.log(...)` and holds two properties of them: the
/// hard rule from the diagnostic-log design's "Never logged" paragraph
/// (NEGATIVE — no interpolation `\(…)` inside a call's arguments names an
/// identifier that looks like a secret), and, beside it, two POSITIVE
/// checks that keep the negative from going stale in silence the way
/// "Guards that name what they watch" describes: `grep -rc
/// "DiagnosticLog.shared.log("` over `Sources/`, summed, reports **39** as
/// of 2026-09-06 (re-counted in Task 5's round 2, which added the second
/// `reason:` overload wrapper in `TunnelRunner`; 38 before it, 27 on
/// 2026-09-05). That grep and this scan do NOT count the same thing, and
/// the difference is two: the grep counts the literal text wherever it
/// appears, INCLUDING inside a doc comment — `TabDetachSequence.swift` and
/// `TunnelRunner.swift` each spell it in prose — while this scan blanks
/// comments first and sees 37 real calls. Both numbers are stated because
/// either one alone is a claim somebody will later check with the other's
/// method. (`docs/BACKLOG.md` records 27, the number measured on
/// 2026-09-05; that row is a dated record of that day, not a claim about
/// HEAD.) The assertion below holds the threshold at 20 rather than any
/// exact number, deliberately: it exists to catch a wholesale regression
/// (the scan losing its footing, or most of the instrumentation being
/// reverted), not to be re-edited on every call site a later task adds or
/// removes — see `noInterpolationNamesASecretIdentifier`'s own assertion
/// message for the up-to-date count if this ever goes red. Every category
/// literal used is also checked against the fixed nine the diagnostic-log
/// design settled on plus the one the port-forwarding plan added.
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

    /// The fixed category list: the eight the diagnostic-log design settled
    /// on, plus `tunnel`, added by Task 5 of the port-forwarding plan for
    /// `TunnelRunner`'s own lines (`tunnel <name> start|active port=…|
    /// failed …|reconnecting attempt=…|stop` at `.info`, one `.debug` line
    /// per accepted connection). Nine as of 2026-09-06, counted in this
    /// pass. A category outside this list is either a typo (a line nobody
    /// can filter on the way the design's other lines can) or an
    /// undocumented tenth category that needs a decision, not a silent
    /// addition.
    private static let fixedCategories: Set<String> = [
        "app", "browser.local", "browser.remote", "connect", "sftp",
        "shell", "transfer", "error", "tunnel",
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

    /// One file's forwarded call sites, with the categories that file's own
    /// DIRECT sites use — so the positive below can ask what a given category
    /// actually contributes to the scan.
    private struct ForwardedSites {
        let file: String
        let categories: Set<String>
        let sites: [CallSite]
    }

    /// Call sites of a file's OWN wrapper around the marker.
    ///
    /// The hole this closes (round 2 of the port-forwarding plan's Task 5,
    /// found in review): the negative check reads the `\(…)` inside a
    /// marker call's arguments, and a file that routes every line through a
    /// private wrapper has exactly one marker call whose arguments are the
    /// wrapper's own parameters — `level, "tunnel", message()`. No
    /// interpolation, nothing to scan, and the negative check passes for the
    /// whole category by finding nothing to look at. That is precisely the
    /// "a negative check that starts matching nothing reads exactly like a
    /// check that is satisfied" failure CLAUDE.md's "Guards that name what
    /// they watch" describes, and `TunnelRunner` was in it: its two wrappers
    /// were the only scanned spans for the `tunnel` category, and the real
    /// lines — the ones that interpolate — were invisible.
    ///
    /// Structural, not by name. A forwarder is a function whose BODY
    /// contains the marker, found by brace-matching over the
    /// strings-and-comments-blanked text (so a brace inside a literal cannot
    /// close a body early) and taking the innermost such function per marker
    /// occurrence. Its own call sites in the same file are then collected the
    /// same way the marker's are. The marker occurrences are blanked out
    /// first, because `DiagnosticLog.shared.log(` ends in `log(` and would
    /// otherwise match a forwarder named `log`; a declaration (`func log(`)
    /// is skipped for the same reason.
    ///
    /// Deliberately NOT limited to `TunnelRunner`, or to a wrapper named
    /// `log`: whatever helper a file routes its lines through gets scanned,
    /// which is the property this check is supposed to have.
    private static func collectForwardedCallSites() throws -> [ForwardedSites] {
        var collected: [ForwardedSites] = []
        for file in swiftFiles(under: sourcesRoot) {
            let raw = try String(contentsOf: file, encoding: .utf8)
            let stripped = try SwiftSource.stripComments(raw)
            guard !stripped.contains("final class DiagnosticLog: Sendable") else { continue }
            let markers = Self.occurrences(of: marker, in: stripped)
            guard !markers.isEmpty else { continue }
            let blanked = try SwiftSource.stripCommentsAndStrings(raw)
            let names = Self.forwarderNames(markerStarts: markers, blanked: blanked)
            guard !names.isEmpty else { continue }

            var chars = Array(stripped)
            for start in markers {
                for index in start..<min(start + marker.count, chars.count) { chars[index] = " " }
            }
            let scannable = String(chars)
            var sites: [CallSite] = []
            for name in names.sorted() {
                sites.append(
                    contentsOf: Self.callSites(
                        callingFunctionNamed: name, in: scannable,
                        file: file.lastPathComponent))
            }
            guard !sites.isEmpty else { continue }
            let categories = Set(
                Self.callSites(in: stripped, file: file.lastPathComponent)
                    .compactMap { Self.categoryLiteral(in: $0.arguments) })
            collected.append(
                ForwardedSites(
                    file: file.lastPathComponent, categories: categories, sites: sites))
        }
        return collected
    }

    /// Character offsets of every occurrence of `needle` in `text`.
    private static func occurrences(of needle: String, in text: String) -> [Int] {
        var found: [Int] = []
        var searchFrom = text.startIndex
        while let range = text.range(of: needle, range: searchFrom..<text.endIndex) {
            found.append(text.distance(from: text.startIndex, to: range.lowerBound))
            searchFrom = range.upperBound
        }
        return found
    }

    /// The name of the innermost function whose body contains each marker
    /// occurrence.
    private static func forwarderNames(markerStarts: [Int], blanked: String) -> Set<String> {
        let spans = Self.functionSpans(in: blanked)
        var names: Set<String> = []
        for start in markerStarts {
            let enclosing = spans
                .filter { $0.body.contains(start) }
                .min { $0.body.count < $1.body.count }
            if let enclosing { names.insert(enclosing.name) }
        }
        return names
    }

    private struct FunctionSpan {
        let name: String
        let body: Range<Int>
    }

    /// Every `func <name>` in `blanked`, with its brace-matched body.
    ///
    /// `blanked` must be the strings-AND-comments-blanked text: a `{` inside
    /// a string literal would otherwise open a body that never closes where
    /// it should. Both stripping modes are length-preserving, so the offsets
    /// this returns index the comments-only text just as well.
    private static func functionSpans(in blanked: String) -> [FunctionSpan] {
        let chars = Array(blanked)
        var spans: [FunctionSpan] = []
        var i = 0
        let keyword = Array("func ")
        while i + keyword.count < chars.count {
            guard Array(chars[i..<(i + keyword.count)]) == keyword else {
                i += 1
                continue
            }
            let before = i == 0 ? " " : chars[i - 1]
            guard !before.isLetter, !before.isNumber, before != "_" else {
                i += 1
                continue
            }
            var nameEnd = i + keyword.count
            while nameEnd < chars.count,
                chars[nameEnd].isLetter || chars[nameEnd].isNumber || chars[nameEnd] == "_"
            {
                nameEnd += 1
            }
            let name = String(chars[(i + keyword.count)..<nameEnd])
            guard !name.isEmpty else {
                i += 1
                continue
            }
            var open = nameEnd
            while open < chars.count, chars[open] != "{" { open += 1 }
            guard open < chars.count else { break }
            var depth = 0
            var j = open
            while j < chars.count {
                if chars[j] == "{" { depth += 1 }
                if chars[j] == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                j += 1
            }
            guard j < chars.count else {
                i = nameEnd
                continue
            }
            spans.append(FunctionSpan(name: name, body: (open + 1)..<j))
            i = nameEnd
        }
        return spans
    }

    /// Every call to `name(` in `text` that is not its own declaration, with
    /// the same brace-balanced argument extraction the marker gets.
    private static func callSites(
        callingFunctionNamed name: String, in text: String, file: String
    ) -> [CallSite] {
        var results: [CallSite] = []
        let chars = Array(text)
        var searchFrom = text.startIndex
        let needle = name + "("
        while let range = text.range(of: needle, range: searchFrom..<text.endIndex) {
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            searchFrom = range.upperBound
            // A longer identifier ending in `name` is a different function.
            if start > 0 {
                let before = chars[start - 1]
                if before.isLetter || before.isNumber || before == "_" { continue }
            }
            // `func name(` is the declaration, not a call.
            var back = start - 1
            while back >= 0, chars[back] == " " { back -= 1 }
            if back >= 3, String(chars[(back - 3)...back]) == "func" { continue }

            var i = start + needle.count
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
            guard depth == 0 else { break }
            results.append(CallSite(file: file, arguments: String(chars[argStart..<(i - 1)])))
        }
        return results
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
        let direct = try Self.collectCallSites()
        let forwarded = try Self.collectForwardedCallSites()
        let sites = direct + forwarded.flatMap(\.sites)
        #expect(
            direct.count >= 20,
            """
            only \(direct.count) DiagnosticLog.shared.log( call sites found under Sources/ — \
            the scan is not reaching the files it is meant to guard, or the instrumentation \
            this task added regressed.
            """)

        // The second positive, and the one round 2 added: a category whose
        // lines all go through a file's own wrapper contributes NOTHING to
        // the negative below unless `collectForwardedCallSites()` reaches
        // them — the wrapper's own marker call interpolates nothing at all.
        // `tunnel` is that category (`TunnelRunner` is the only file under
        // Sources/ that wraps the marker as of 2026-09-06), so it is the one
        // named here; a rewrite that broke the forwarding walk would drive
        // this to zero while every other check stayed green.
        let tunnelInterpolations = forwarded
            .filter { $0.categories.contains("tunnel") }
            .flatMap { $0.sites }
            .flatMap { Self.interpolations(in: $0.arguments) }
        #expect(
            tunnelInterpolations.count > 0,
            """
            the tunnel category contributed no scanned interpolations at all — its lines are \
            written through a wrapper, so without the forwarding walk the negative check below \
            reads an empty span and passes by finding nothing to look at.
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
        var usedLiterals: Set<String> = []
        var resolvedIdentifiers: Set<String> = []
        for site in sites {
            if let category = Self.categoryLiteral(in: site.arguments) {
                usedLiterals.insert(category)
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

        // The positive beside the list itself. A `fixedCategories` entry
        // nobody writes is a list that has stopped describing the tree, and
        // the check above cannot notice: it only ever reads the list to
        // ACCEPT with, so an entry for a category no call site uses is
        // silently fine — the "only a NEGATIVE check can go stale in
        // silence" shape from CLAUDE.md, one level up. Every entry is
        // required to be reached by at least one call site whose category
        // is a plain literal, EXCEPT the two `RemoteBrowserViewModel`
        // passes dynamically through `logCategory` (checked above by
        // resolving that identifier's literal values instead).
        let dynamicOnly: Set<String> = ["browser.local", "browser.remote"]
        let unusedEntries = Self.fixedCategories.subtracting(usedLiterals)
            .subtracting(dynamicOnly).sorted()
        #expect(
            unusedEntries.isEmpty,
            """
            \(unusedEntries) are on the fixed category list but no \
            DiagnosticLog.shared.log(...) call under Sources/ spells any of them as a literal \
            category — either the instrumentation that used them was removed (and the list \
            should shrink with it) or the scan is no longer reading the calls.
            """)
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
