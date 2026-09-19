import Foundation
import MacSCPTestSupport
import Testing

/// Scans every `.swift` file under `Sources/` for calls to
/// `DiagnosticLog.shared.log(...)` and holds two properties of them: the
/// hard rule from the diagnostic-log design's "Never logged" paragraph
/// (NEGATIVE — no interpolation `\(…)` inside a call's arguments names an
/// identifier that looks like a secret), and, beside it, SIX POSITIVE checks
/// — counted 2026-09-06 by listing every `#expect` outside this file's
/// self-tests that asserts the scan FOUND something rather than nothing:
///
/// 1. `noInterpolationNamesASecretIdentifier`: the direct call-site floor
///    (`direct.count >= 20`).
/// 2. …: each of the SEVEN files measured as having its wrapper call sites
///    reached by the forwarding walk still yields them
///    (`filesWithReachableForwardedSites` — counted 2026-09-06 by listing
///    that set, which is seven names long).
/// 3. …: the `tunnel` category yields forwarded call sites at all.
/// 4. …: every one of those `tunnel` sites carries an interpolation.
/// 5. `everyCategoryLiteralIsOnTheFixedList`: every entry on
///    `fixedCategories` is reached by at least one call site.
/// 6. `noHandWrittenMessageSpellsReasonEquals`: at least three call sites use
///    the `reason:` overload.
///
/// They keep the negative from going stale in silence the way
/// "Guards that name what they watch" describes: `grep -rc
/// "DiagnosticLog.shared.log("` over `Sources/`, summed, reports **47** as
/// of 2026-09-19 — recounted by running exactly that command and summing its
/// per-file numbers. 47 is one more than 46 because Task 2 fix round 2 of
/// the 2026-09-19 plan added one call in `S3Uploader.logUnconfirmedAbort(_:)`
/// (the line written when a multipart abort is not confirmed). 46 was one
/// more than 45 because Task 2 fix round 1 of
/// the 2026-09-19 plan added one call in `ThroughputProbe.logLeftover(_:)`
/// (the line written when a throughput test file may remain on a server).
/// 45 was one more than 44 because Task 6 of the review
/// follow-ups of 2026-09-18 added one call in
/// `ManagedKeyPassphraseSecretSource.secret(for:)` (the line written when
/// `managed_keys.json` cannot be read). 44 was two more than the 42 this
/// paragraph carried,
/// because Task 3 of the technical backlog of 2026-09-16 added two calls in
/// `SOCKS5Handshake.negotiate(on:limits:)` (the lines written when a SOCKS5
/// handshake is refused over the parked-handshake cap, and when one times
/// out). 42 came
/// from Task 2 of the same plan, a call in
/// `TunnelManager.forgetEverything(for:)` (the line written when a deleted
/// session's profiles cannot be removed from `tunnels.json`). The preceding
/// numbers, newest first: 41 came from the CLI-store plan's Task 5 round 2,
/// a call in `TunnelManager.swift` (the line written when `tunnels.json`
/// cannot be read and the activation reconcile therefore changes nothing);
/// 40 from the port-forwarding plan's
/// Task 6 round 3 (`7046da25`), a call in `MacSCPApp.swift`; 39 from that
/// plan's Task 5 round 2, which added the second `reason:` overload wrapper
/// in `TunnelRunner`; 38 before it, and 27 on 2026-09-05. That grep and this scan
/// do NOT count the same thing, and the difference is two: the grep counts
/// the literal text wherever it appears, INCLUDING inside a doc comment —
/// `TabDetachSequence.swift` and `TunnelRunner.swift` each spell it in prose
/// — while this scan blanks comments first and sees 45 real calls on
/// 2026-09-19 after fix round 2, and saw 44 after fix round 1 (both read
/// from the floor's own message with the floor raised to 999 by a probe,
/// reverted and checked with `cmp`), 44 being one more than the 43 of
/// 2026-09-18 for fix round 1's call. The 43 was one more for its own call,
/// measured the way the 42 was (42
/// on 2026-09-16, 40 before
/// Task 3's two calls and 39 before Task 2's, all 2026-09-16; each recounted
/// that day with this file's own `callSites(in:file:)` — the 43 and the 42 by
/// temporarily raising this file's `direct.count` floor until it failed and
/// reading the count from its message). Both numbers are stated because
/// either one alone is a claim somebody will later check with the other's
/// method. (`docs/BACKLOG.md` records 27, the number measured on
/// 2026-09-05; that row is a dated record of that day, not a claim about
/// HEAD.) The assertion below holds the threshold at 20 rather than any
/// exact number, deliberately: it exists to catch a wholesale regression
/// (the scan losing its footing, or most of the instrumentation being
/// reverted), not to be re-edited on every call site a later task adds or
/// removes — see `noInterpolationNamesASecretIdentifier`'s own assertion
/// message for the up-to-date count if this ever goes red. Every category
/// literal used is also checked against the fixed NINE — the diagnostic-log
/// design's own eight plus `tunnel`, added by the port-forwarding plan;
/// counted 2026-09-06 against `fixedCategories` itself, which is the array
/// this sentence describes.
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

    /// The files under `Sources/` in which the forwarding walk actually
    /// LOCATES a wrapper's call sites — SEVEN, measured 2026-09-06 by
    /// running the walk and printing what it collects per file (the table is
    /// in `noInterpolationNamesASecretIdentifier`, beside the assertion that
    /// reads this list) and recounted against the literal below in the same
    /// pass. It said SIX until 2026-09-06 (CLI-store plan, Task 5 round 4),
    /// having been written before `TunnelManager.swift` joined the literal
    /// below — the number and the list disagreed, in a file whose own
    /// subject is that a count is a claim to be recounted.
    ///
    /// It is a measurement, not a name the guard could derive: the walk's own
    /// output is what would have to be trusted to derive it, and a check whose
    /// antecedent comes from the thing under test cancels out — extraction
    /// that stops finding a wrapper's calls also stops the fixpoint growing
    /// onto its callers, so the file quietly leaves the set the check
    /// quantifies over. Naming the seven files is what makes the check able to
    /// fail: break the extraction for any one of their wrappers and that file
    /// stops yielding sites while its name stays here.
    ///
    /// TWELVE files have a forwarder; the five absent from this list have a
    /// name set equal to their seed set — no wrapper, an ordinary function
    /// holding a line that the direct scan reads. Adding them would be red on
    /// correct code.
    ///
    /// **`TunnelManager.swift` joined on 2026-09-06** (CLI-store plan, Task 5
    /// round 3), when its unreadable-store line was written inside
    /// `performReconcilingReload()` — a private function `reloadReconciling()`
    /// calls, so the walk seeds on it and grows onto its caller. The list did
    /// NOT go red when that happened, and the reason is worth naming: the
    /// assertion in `noInterpolationNamesASecretIdentifier` is a SUBSET check
    /// in one direction — every file named here must still yield sites — so a
    /// file that STARTS yielding them is invisible to it. That is deliberate
    /// (the other direction would be red on correct code, see above), and it
    /// is exactly why this list has to be recounted by hand whenever a marker
    /// call moves into a function something else calls.
    private static let filesWithReachableForwardedSites: Set<String> = [
        "CitadelFileSystem.swift", "ContentView+Lifecycle.swift",
        "MacSCPApp.swift", "RemoteBrowserViewModel.swift",
        "TunnelManager.swift", "TunnelRunner.swift", "TunnelStore.swift",
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
        /// Every collected site — the seeded wrappers' own call sites plus
        /// those of every function the fixpoint grew onto.
        let sites: [CallSite]
        /// Only the SEEDED wrappers' call sites: the functions that contain
        /// the marker themselves. These are the actual log lines of the
        /// file; the grown ones are the calls that lead to them, which carry
        /// whatever their own callers pass and need not interpolate anything.
        let seeded: [CallSite]
    }

    /// What one file's walk found, split by how each forwarder was reached.
    private struct WalkResult {
        let all: [CallSite]
        let seeded: [CallSite]
        /// Every forwarder NAME the walk found in this file — reported
        /// independently of whether any of their call sites were then
        /// located.
        ///
        /// It is reported separately because the two questions were
        /// conflated in round 3 of the port-forwarding plan's Task 5, and its
        /// re-review caught it: the collection skipped a file whose call-site
        /// list came back empty, which made every entry it returned non-empty
        /// BY CONSTRUCTION — and the per-file positive asserting exactly that
        /// could never be false. A check that cannot fail is not a guard.
        /// Naming a wrapper and then locating none of its calls is the silent
        /// breakage that positive is for, so `hasForwarders` is what the
        /// collection filters on and the call sites are what it asserts
        /// about.
        let names: Set<String>
        var hasForwarders: Bool { !names.isEmpty }
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
            let walked = Self.walk(
                stripped: stripped, blanked: blanked, file: file.lastPathComponent)
            // Filter on whether the walk NAMED a wrapper here, never on
            // whether it found that wrapper's calls. Filtering on the call
            // sites would drop exactly the files the per-file positive in
            // `noInterpolationNamesASecretIdentifier` exists to catch, and
            // would leave every surviving entry non-empty by construction —
            // an assertion that cannot be false. See `WalkResult`.
            guard walked.hasForwarders else { continue }
            let categories = Set(
                Self.callSites(in: stripped, file: file.lastPathComponent)
                    .compactMap { Self.categoryLiteral(in: $0.arguments) })
            collected.append(
                ForwardedSites(
                    file: file.lastPathComponent, categories: categories,
                    sites: walked.all, seeded: walked.seeded))
        }
        return collected
    }

    /// The pure half of `collectForwardedCallSites()`, over one file's text —
    /// so a self-test can plant a wrapper and check the walk reaches through
    /// it without touching the file system.
    private static func forwardedCallSites(stripped: String, blanked: String, file: String)
        -> [CallSite]
    {
        Self.walk(stripped: stripped, blanked: blanked, file: file).all
    }

    private static func walk(stripped: String, blanked: String, file: String) -> WalkResult {
        let markers = Self.occurrences(of: marker, in: stripped)
        guard !markers.isEmpty else {
            return WalkResult(all: [], seeded: [], names: [])
        }
        let seeds = Self.seedForwarderNames(markerStarts: markers, blanked: blanked)
        let names = Self.forwarderNames(markerStarts: markers, blanked: blanked)
        guard !names.isEmpty else {
            return WalkResult(all: [], seeded: [], names: [])
        }

        // The marker text ends in `log(`, which would match a forwarder
        // actually named `log`; blanking the marker occurrences first is what
        // keeps the two apart.
        var chars = Array(stripped)
        for start in markers {
            for index in start..<min(start + marker.count, chars.count) { chars[index] = " " }
        }
        let scannable = String(chars)
        var sites: [CallSite] = []
        var seeded: [CallSite] = []
        for name in names.sorted() {
            let found = Self.callSites(callingFunctionNamed: name, in: scannable, file: file)
            sites.append(contentsOf: found)
            if seeds.contains(name) { seeded.append(contentsOf: found) }
        }
        return WalkResult(all: sites, seeded: seeded, names: names)
    }

    /// The innermost function whose body contains each marker occurrence —
    /// the fixpoint's seed, before it grows onto callers.
    private static func seedForwarderNames(markerStarts: [Int], blanked: String) -> Set<String> {
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

    /// Every function in the file that reaches the marker — directly, or
    /// through another such function, to any depth.
    ///
    /// **Iterated to a fixpoint**, which is round 3's correction. One layer
    /// was not enough: a file that wraps the marker in `emit` and wraps
    /// `emit` in `log` would have had `emit`'s own call sites collected (one
    /// call, inside `log`, carrying nothing) and `log`'s real call sites —
    /// the ones that interpolate — left invisible, silently, exactly the way
    /// the wrapper hid `TunnelRunner`'s lines in the first place.
    /// `selfTestTheWalkReachesATwoLayerWrapper` plants that shape.
    ///
    /// Seeded with the INNERMOST function whose body contains a marker
    /// occurrence, then grown: a function whose body calls a known forwarder
    /// becomes one. The growth cannot run away — it is bounded by the number
    /// of functions in the file, and every pass adds at least one name or
    /// stops.
    ///
    /// **What it still cannot reach**, stated rather than implied: a marker
    /// inside a computed property, an `init`, or a stored closure has no
    /// enclosing `func`, so nothing is seeded for that file at all. Extending
    /// the seed to those shapes would name them but buy nothing — a property
    /// read has no argument list, so there is no span for this scan to read
    /// — and the honest fix for such a file would be to give it a `func`
    /// wrapper or to let its lines interpolate at the marker. The per-file
    /// positive in `noInterpolationNamesASecretIdentifier` does not catch it
    /// either: a file with no forwarder is simply absent from the walk's
    /// result.
    private static func forwarderNames(markerStarts: [Int], blanked: String) -> Set<String> {
        let spans = Self.functionSpans(in: blanked)
        var names = Self.seedForwarderNames(markerStarts: markerStarts, blanked: blanked)
        guard !names.isEmpty else { return names }

        let chars = Array(blanked)
        var grew = true
        while grew {
            grew = false
            for span in spans where !names.contains(span.name) {
                let body = String(chars[span.body])
                let callsAForwarder = names.contains { name in
                    !Self.callSites(callingFunctionNamed: name, in: body, file: "").isEmpty
                }
                if callsAForwarder {
                    names.insert(span.name)
                    grew = true
                }
            }
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

        // Positives 2, 3 and 4 (see this type's doc comment): a file that
        // routes its lines through its own wrapper contributes NOTHING to the
        // negative below unless `collectForwardedCallSites()` reaches it — the
        // wrapper's own marker call interpolates nothing at all.
        //
        // Positive 2 is round 4's replacement for a check that could not fail.
        // Round 3 asserted, per collected file, that the walk yielded at least
        // one call site — but the collection SKIPPED a file whose call-site
        // list came back empty, so every entry it returned was non-empty by
        // construction and the assertion was dead code wearing a guard's
        // failure message. The collection now filters on whether the walk
        // NAMED a forwarder (see `WalkResult`), which made the observation
        // possible and showed round 3's property to be not merely dead but
        // FALSE.
        //
        // Measured 2026-09-06 by running the walk and printing what it
        // collects, per file, with the name set split into seeds and the names
        // the fixpoint grew onto — RE-RUN the same way on 2026-09-06 for the
        // CLI-store plan's Task 5 round 3, which is where every number below
        // comes from except the two `Tunnel` rows, re-run on 2026-09-16 for
        // Task 2 of that day's technical backlog (that run measured only
        // those two files, after reproducing both of their 2026-09-06 rows on
        // the parent commit). TWELVE files under `Sources/` have a forwarder;
        // SEVEN of them yield call sites:
        //
        //   file                       all  seeded  names  seeds  direct
        //   CitadelFileSystem           23      11     13      1       2
        //   TunnelRunner                18       9      9      1       2
        //   RemoteBrowserViewModel       8       8      9      1       2
        //   ContentView+Lifecycle        7       4      8      2       2
        //   MacSCPApp                    7       5      6      4       6
        //   TunnelStore                  3       3      4      1       1
        //   TunnelManager                3       2      4      2       2
        //
        // 2026-09-16: `TunnelStore` was `6 6 7 1 1` — its three writes stopped
        // reading through the marker-holding `load()`, so `upsert`, `delete`
        // and `deleteAll` left the name set and their three call sites left
        // the walk. `TunnelManager` was `3 1 4 1 1` — a second marker call,
        // in `forgetEverything(for:)`, made that function a seed as well.
        //
        // Three rows moved and one is new, and the re-run is what found them:
        // `TunnelManager` because round 3 put its unreadable-store line inside
        // a private function its own entry point calls; `TunnelStore` because
        // round 2 moved the decode into `decode()`, which `readProfiles()`
        // reaches WITHOUT going through the marker-holding `load()`, so one
        // name and one call site left the walk; and `MacSCPApp`, which this
        // table had recorded as `6 4 5 3 5` — stale since the port-forwarding
        // plan's own final round added the call that took the tree from 39 to
        // 40. A table nobody re-runs is a comment, not a measurement.
        //
        // and FIVE yield none, correctly — `CitadelShell`, `ConnectionViewModel`,
        // `LocalFileSystem`, `LocalMetadataSource`, `TransferEngine`. In every
        // one of those the name set equals the seed set: the fixpoint never
        // grew, because the function holding the marker is ordinary public API
        // that nothing in its own file calls. There is no wrapper to reach
        // through and nothing hidden — those lines interpolate at the marker
        // (or are constant messages, as all three of `CitadelShell`'s are) and
        // the DIRECT scan reads them. Requiring call sites there would be red
        // on correct code, which is why the assertion below names the files it
        // watches instead of quantifying over everything the walk touches.
        //
        // `CitadelFileSystem`'s wrapper is `measured<T>`, and it is the reason
        // the claim this comment used to make — that `TunnelRunner` is the only
        // file under `Sources/` that wraps the marker — was FALSE.
        // `TunnelRunner` is the only file whose whole CATEGORY goes through a
        // wrapper (both of its direct marker sites carry zero interpolations);
        // `measured` interpolates at the marker itself, so the direct scan was
        // never blind there.
        let filesYieldingSites = Set(forwarded.filter { !$0.sites.isEmpty }.map(\.file))
        let unreached = Self.filesWithReachableForwardedSites
            .subtracting(filesYieldingSites).sorted()
        #expect(
            unreached.isEmpty,
            """
            the forwarding walk located none of the wrapper call sites in \(unreached) — \
            each of those files was measured as yielding them, so every line written through \
            a wrapper there is now invisible to the negative below. Either the call-site \
            extraction regressed, or that file stopped logging through a wrapper and this \
            list should shrink with it.
            """)

        // Positives 3 and 4: `TunnelRunner` is the one file whose WHOLE CATEGORY is
        // written through a wrapper — its two direct marker sites carry zero
        // interpolations between them (measured in the same run) — so
        // `tunnel` is the category that vanishes entirely if the walk
        // breaks. Pinned tighter than a bare floor, and derived from the
        // same run rather than from a copied number: every call site of a
        // SEEDED wrapper in that category must carry at least one
        // interpolation, which is true because every one of those lines names
        // the profile.
        //
        // Seeded, not every collected site: the fixpoint also grows onto the
        // functions that CALL a wrapper, and `attempt(decider:isRetry:)`
        // calling `run` has no reason to interpolate anything. Only the
        // wrapper's own call sites are log lines.
        let tunnelSites = forwarded
            .filter { $0.categories.contains("tunnel") }
            .flatMap { $0.seeded }
        #expect(
            tunnelSites.count > 0,
            """
            the tunnel category contributed no scanned call sites at all — its lines are \
            written through a wrapper, so without the forwarding walk the negative check below \
            reads an empty span and passes by finding nothing to look at.
            """)
        let tunnelSitesWithoutInterpolation = tunnelSites
            .filter { Self.interpolations(in: $0.arguments).isEmpty }
            .map(\.arguments)
        #expect(
            tunnelSitesWithoutInterpolation.isEmpty,
            """
            a tunnel line carries no interpolation at all:
            \(tunnelSitesWithoutInterpolation.joined(separator: "\n"))
            Every line that category writes names the profile, so a site with nothing to scan \
            means the walk is reading a span that is not a call site.
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

    /// Positive 5 of the six this file holds (see the type's own doc comment
    /// for the list): every category used is one of the fixed NINE — counted
    /// 2026-09-06 against `fixedCategories` itself —
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

    /// The forwarding walk reaches through TWO layers of wrapper.
    ///
    /// The shape that motivated the fixpoint: `work` interpolates, calls
    /// `log`, which calls `emit`, which calls the marker. One layer of walk
    /// finds only `emit`'s call sites — the single call inside `log`, which
    /// carries nothing — and the interpolation in `work` is invisible. The
    /// planted identifier is a NAME, never a value: nothing here is a secret,
    /// and the expectation below computes its `Bool` from `contains` so no
    /// failure message can print a payload.
    @Test func selfTestTheWalkReachesATwoLayerWrapper() throws {
        let source = """
            final class Noisy {
                private func emit(_ text: String) {
                    DiagnosticLog.shared.log(.info, "app", text)
                }
                private func log(_ text: String) {
                    emit(text)
                }
                func work(password: String) {
                    log("leaking \\(password) here")
                }
            }
            """
        let stripped = try SwiftSource.stripComments(source)
        let blanked = try SwiftSource.stripCommentsAndStrings(source)
        let sites = Self.forwardedCallSites(
            stripped: stripped, blanked: blanked, file: "planted.swift")
        let found = sites
            .flatMap { Self.interpolations(in: $0.arguments) }
            .contains("password")
        #expect(found)
    }

    /// One layer is still reached, and a file with no wrapper at all
    /// contributes nothing — the negative beside the positive above, so a
    /// walk that started returning every identifier in the file would not
    /// pass by over-reaching.
    @Test func selfTestAFileWithNoWrapperYieldsNoForwardedSites() throws {
        let source = """
            final class Plain {
                func work(path: String) {
                    DiagnosticLog.shared.log(.info, "app", "read \\(path)")
                }
                func other(path: String) {
                    work(path: path)
                }
            }
            """
        let stripped = try SwiftSource.stripComments(source)
        let blanked = try SwiftSource.stripCommentsAndStrings(source)
        let sites = Self.forwardedCallSites(
            stripped: stripped, blanked: blanked, file: "planted.swift")
        // `work` IS a forwarder (it contains the marker), so its one call
        // site inside `other` is collected — and `other` becomes a forwarder
        // in the next pass, with no call sites of its own. What matters is
        // that the walk collects call sites, not identifiers: the file's own
        // marker line is read by the DIRECT scan, not by this one.
        #expect(sites.count == 1)
        #expect(sites[0].arguments.contains("path: path"))
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
