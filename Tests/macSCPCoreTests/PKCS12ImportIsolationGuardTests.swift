import Foundation
import Security
import Testing

/// Pins the one line that keeps the test suite out of the user's keychain.
///
/// A stub in this target imports a PKCS#12 bundle through
/// `SecPKCS12Import` on every plain `swift test` — not behind
/// `MACSCP_KEYCHAIN`, not behind `MACSCP_ITEST`. That is allowed, and it is
/// allowed for exactly one reason: the options dictionary carries
/// `kSecImportToMemoryOnly`, which per Security's own header keeps the
/// imported items in process memory and does not consult a keychain at
/// all. Delete that entry and the same call imports a key and a
/// certificate into the login keychain of whoever ran the tests — silently,
/// successfully, and once per run.
///
/// Nothing else holds it. It is one entry in one dictionary literal, and a
/// refactor, a merge, or a copy-paste of the stub into a second one can
/// drop it without a single test going red. That is what this suite is
/// for: the property is not "the stub is correct today" but "no call under
/// `Tests/` reaches the keychain, including the ones nobody has written
/// yet".
///
/// ## Why it needs a positive check beside it
///
/// "No call without the flag" is a NEGATIVE property, and this project has
/// measured what those do when they stop reaching their subject: they
/// match nothing and report success (CLAUDE.md, "Guards that name what
/// they watch"). Rename the stub, move it, delete the call — a scan
/// looking for violations finds none, which reads exactly like a scan that
/// found nothing wrong. So `theScanReachesTheImportSite` asserts the
/// opposite direction: that the walk reaches the tree, that at least one
/// file still mentions the function, and that at least one real call site
/// is still there to be judged. The floor sits inside the checking test as
/// well, so the two cannot drift apart.
///
/// Nothing here is spelled that could be read instead: the roots come from
/// what is on disk under `Tests/` and from what `Package.swift` declares as
/// test targets, so a third test target is scanned without anyone
/// remembering this file. The two exceptions are `SecPKCS12Import` and
/// `kSecImportToMemoryOnly` themselves, which are SDK symbols and cannot be
/// derived from anything in this repo — so
/// `theGuardedSymbolsAreTheOnesTheSDKStillHas` references both as symbols
/// rather than as text, making an SDK rename a compile error in this file
/// instead of a scan that quietly stops matching.
///
/// ## What clears a call, exactly
///
/// A call is cleared only when, for **every** dictionary literal its
/// options argument reaches, the flag is a **top-level** key, written
/// literally (`kSecImportToMemoryOnly`, optionally cast), mapped to a value
/// that is literally one of `truthySpellings` — and the options name is
/// touched nowhere else in the file. Everything else either names the call
/// as an offender or throws:
///
/// - The flag nested inside another entry's value
///   (`kSecImportExportAccess as String: [kSecImportToMemoryOnly …]`) is
///   not a top-level key, so it does not clear anything. `SecPKCS12Import`
///   reads the top level; a scan that searched the literal's whole text
///   cleared that shape, and did so for a dictionary that writes to the
///   default keychain.
/// - A key that only *mentions* the flag inside a larger expression (a
///   ternary, a call) is not a key this scan can read, and reads as absent
///   — which is an offender.
/// - The options name used anywhere but its own literal assignment — a
///   subscript, a member access, an `inout` argument, a compound
///   assignment, or an assignment of something that is not a literal —
///   throws. Building a dictionary with the flag true and then overwriting
///   or removing the entry is the shape that motivated this; the scan
///   cannot follow it, so it stops instead of reading the literal and
///   believing it.
/// - Anything chained onto a literal written into the call itself
///   (`[flag: true].merging(extra) { _, new in new }`) throws. The literal
///   says one thing and the expression delivers another; only an `as` cast
///   is an inert tail.
/// - A literal assigned to the name in a scope that has already CLOSED
///   before the call does not clear it. A careful `options` in one
///   function used to clear a careless `options` parameter in another —
///   file-wide name resolution reading one binding for a different one.
///   `scopeIsOpen` is the cheapest reading of "this binding could be the
///   one that arrives"; a call with no such binding throws.
///
/// ## What this guard cannot REACH
///
/// The list above is about judgement. This one is about reading: these are
/// the calls that never arrive at the judgement in the first place, and no
/// text scan can change that.
///
/// - **A call reached through `dlsym`** or any other runtime lookup names
///   the function nowhere in source, so nothing here sees it.
/// - **A call in a file this walk does not reach.** The roots are what
///   `testRoots()` derives, and `Sources/` is not among them — a call
///   ADDED there is not judged at all. `Sources/` holds zero occurrences
///   of the name today (counted this pass; the two files that spell it are
///   `LoopbackTLSStub.swift` and this one), and a call that MOVED out of
///   `Tests/` altogether would trip `theScanReachesTheImportSite`'s
///   candidate floor loudly — but a second call added beside the existing
///   one, under `Sources/`, trips nothing.
/// - **This file itself**, which is excluded for the reason given at
///   `ownFile`.
/// - **The keychain proper.** Nothing here observes what a run actually
///   wrote; it reads source. A test that deliberately writes to the
///   keychain behind `MACSCP_KEYCHAIN` is a different property, guarded
///   elsewhere.
///
/// Two deliberate over-strictnesses, stated so neither is mistaken for a
/// gap. A name assigned several literals whose scopes are all open at the
/// call must carry the flag in every one of them, because the scan does not
/// know which arrives. And `unaccountedUse` is judged over the whole FILE,
/// not the scope: a `.count` on an unrelated `options` three functions away
/// stops the scan. Both cost a false alarm, neither a silent pass — and
/// this paragraph is the one to distrust first, since it is the claim that
/// was wrong the last time it was written.
@Suite("PKCS#12 import isolation", .timeLimit(.minutes(1)))
struct PKCS12ImportIsolationGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPCoreTests/PKCS12ImportIsolationGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static var testsDirectory: URL { repoRoot.appendingPathComponent("Tests") }

    /// This file, derived rather than named.
    ///
    /// `theGuardedSymbolsAreTheOnesTheSDKStillHas` references
    /// `SecPKCS12Import` without calling it, which is precisely the shape
    /// the scan refuses to interpret — an uncalled reference could be
    /// stored, passed on and invoked anywhere, so the scan throws on it
    /// rather than guess. Excluding this one file is what lets that anchor
    /// exist. `theScanReachesTheImportSite` asserts the walk reaches this
    /// file *before* it is removed, so the exclusion cannot rot into an
    /// exclusion of nothing.
    private static let ownFile = URL(fileURLWithPath: #filePath).standardizedFileURL

    /// The function whose every call this suite judges, and the entry that
    /// makes a call acceptable. Text, because a scan reads text — held to
    /// the real symbols by the compile-time anchor named above.
    private static let importFunctionName = "SecPKCS12Import"
    private static let memoryOnlyFlagName = "kSecImportToMemoryOnly"

    /// What counts as "yes" for the flag. Two spellings, counted in the
    /// pass that writes this sentence: the CoreFoundation boolean the
    /// dictionary's `Any` values normally carry, and a plain Swift `true`.
    /// Anything else — `kCFBooleanFalse`, `false`, a computed value the
    /// scan cannot evaluate — is not accepted, so an unreadable value
    /// fails rather than passes.
    private static let truthySpellings = ["kCFBooleanTrue", "true"]

    // MARK: - What a scan that cannot read something must do

    private enum ScanError: Error, CustomStringConvertible {
        case referencedWithoutACall(location: String)
        case tooFewArguments(location: String, count: Int)
        case unreadableOptions(location: String, expression: String)
        case optionsNotFound(location: String, name: String)
        case optionsOutOfScope(location: String, name: String)
        case optionsTouchedElsewhere(location: String, name: String, use: String)
        case unbalanced(location: String)
        case unbalancedDictionary(dictionary: String)

        var description: String {
            switch self {
            case .referencedWithoutACall(let location):
                return """
                    \(location): `\(importFunctionName)` is referenced without being called \
                    there. A stored reference can be invoked anywhere with any options, which \
                    this scan cannot follow — so it stops instead of passing.
                    """
            case .tooFewArguments(let location, let count):
                return """
                    \(location): `\(importFunctionName)` called with \(count) argument(s); the \
                    options dictionary is the second one. The call does not have the shape this \
                    scan knows how to judge.
                    """
            case .unreadableOptions(let location, let expression):
                return """
                    \(location): the options argument `\(expression)` is neither a dictionary \
                    literal nor a name this scan can resolve. Write the options as a literal, \
                    or teach this scan the shape — do not leave it guessing.
                    """
            case .optionsNotFound(let location, let name):
                return """
                    \(location): options `\(name)` is not assigned a dictionary literal anywhere \
                    in that file, so this scan cannot see what it contains.
                    """
            case .optionsOutOfScope(let location, let name):
                return """
                    \(location): options `\(name)` is assigned a dictionary literal in that \
                    file, but in no scope that encloses this call. Another function's local, or \
                    a parameter of the same name, is not the dictionary that reaches here — and \
                    reading one for the other is how a careless call gets cleared by a careful \
                    one three functions away.
                    """
            case .optionsTouchedElsewhere(let location, let name, let use):
                return """
                    \(location): options `\(name)` is also reached as \(use) in that file. This \
                    scan reads the literal the name was assigned and nothing else, so a value \
                    written, removed or replaced afterwards is invisible to it — and a \
                    dictionary that carried the flag when it was written need not carry it when \
                    it reaches the call. Write the options as one literal that is never touched \
                    again, or teach this scan the shape.
                    """
            case .unbalanced(let location):
                return """
                    \(location): unbalanced brackets around the call — the file does not parse.
                    """
            case .unbalancedDictionary(let dictionary):
                return """
                    unbalanced brackets in the options literal `\(dictionary)` — its top-level \
                    entries cannot be read, so nothing about it can be cleared.
                    """
            }
        }
    }

    // MARK: - Where to look

    private static var fileManager: FileManager { .default }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func captures(_ pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// A directory URL's path carries a trailing slash, and `repoRoot` is
    /// itself built by walking `#filePath` up — so both ends of this
    /// subtraction need the same spelling before either can be a prefix of
    /// the other.
    private static func absolutePath(of url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func relativePath(of url: URL) -> String {
        let root = absolutePath(of: repoRoot)
        let path = absolutePath(of: url)
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    /// The relative directories `Package.swift` declares test targets in.
    ///
    /// `path:` is honoured, for the same reason
    /// `LocalizationCatalogs.targetDirectories` honours it: a target's
    /// sources need not live under `Tests/<name>` at all, and a scan that
    /// assumed they do would drop such a target without a word. Read per
    /// declaration rather than by grepping every `path:` in the file, so a
    /// shipped target's `path:` cannot become a test root.
    static func manifestTestRoots() throws -> [String] {
        let manifest = try String(
            contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        var roots: [String] = []
        // Everything from one `.testTarget(` to the start of the next
        // target declaration is that declaration's argument text.
        for declaration in manifest.components(separatedBy: ".testTarget(").dropFirst() {
            let body = declaration
                .components(separatedBy: ".executableTarget(")[0]
                .components(separatedBy: ".target(")[0]
            guard let name = try captures(#"name:\s*"([^"]+)""#, in: body).first else { continue }
            if let path = try captures(#"path:\s*"([^"]+)""#, in: body).first {
                roots.append(path)
            } else {
                roots.append("Tests/\(name)")
            }
        }
        return roots
    }

    /// Every test root, from disk and from the manifest both — a target
    /// declared in `Package.swift` and a directory sitting under `Tests/`
    /// are each reason enough to read it.
    static func testRoots() throws -> [URL] {
        var relative: Set<String> = []
        for entry in try fileManager.contentsOfDirectory(
            at: testsDirectory, includingPropertiesForKeys: [.isDirectoryKey]) where
            isDirectory(entry)
        {
            relative.insert("Tests/\(entry.lastPathComponent)")
        }
        for root in try manifestTestRoots() { relative.insert(root) }
        return relative.sorted()
            .map { repoRoot.appendingPathComponent($0) }
            .filter { isDirectory($0) }
    }

    /// Every Swift file under those roots, this one included — the walk
    /// has to reach it for `theScanReachesTheImportSite` to be able to say
    /// that excluding it excludes something.
    static func swiftFiles() throws -> [URL] {
        var files: [URL] = []
        for root in try testRoots() {
            guard let walk = fileManager.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
            else { continue }
            for case let url as URL in walk where url.pathExtension == "swift" {
                files.append(url.standardizedFileURL)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// The files worth parsing: the ones whose bytes mention the function
    /// at all.
    ///
    /// Not an optimization. `SwiftSource.stripCommentsAndStrings` refuses
    /// raw strings, which are ordinary in this tree, so stripping every
    /// test file would throw on files that could not hold a call in the
    /// first place — and a guard that throws on unrelated files is a guard
    /// somebody switches off. A file that never spells the function does
    /// not call it (barring a runtime lookup; see this suite's gaps), and
    /// every file that DOES spell it is still read through the fail-closed
    /// stripper.
    ///
    /// A file that cannot be read as text is kept rather than skipped, so
    /// the read fails later where it is a failure, instead of quietly
    /// shrinking the set this scan believes it covered.
    static func candidateFiles() throws -> [URL] {
        try swiftFiles().filter { url in
            url != ownFile
                && ((try? String(contentsOf: url, encoding: .utf8))?
                    .contains(importFunctionName) ?? true)
        }
    }

    // MARK: - Reading a call

    struct CallSite {
        let location: String
        let arguments: [String]
        /// The dictionary literal(s) the options argument reaches. More
        /// than one when a name is assigned a literal in several places —
        /// then every one of them has to carry the flag, because the scan
        /// does not know which reaches the call.
        let dictionaries: [String]
    }

    private static func normalized(_ text: some StringProtocol) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
    }

    /// Every call in one file's source, with its options resolved.
    static func callSites(inSource source: String, file: String) throws -> [CallSite] {
        let stripped = try SwiftSource.stripCommentsAndStrings(source)
        let chars = Array(stripped)
        let regex = try NSRegularExpression(
            pattern: "(?<![A-Za-z0-9_])\(importFunctionName)(?![A-Za-z0-9_])")
        let range = NSRange(stripped.startIndex..., in: stripped)
        var sites: [CallSite] = []
        for match in regex.matches(in: stripped, range: range) {
            guard let matchRange = Range(match.range, in: stripped) else { continue }
            let line = stripped[..<matchRange.lowerBound].filter { $0 == "\n" }.count + 1
            let location = "\(file):\(line)"
            var index = stripped.distance(from: stripped.startIndex, to: matchRange.upperBound)
            while index < chars.count, chars[index] == " " || chars[index] == "\n"
                || chars[index] == "\t"
            {
                index += 1
            }
            guard index < chars.count, chars[index] == "(" else {
                throw ScanError.referencedWithoutACall(location: location)
            }
            let arguments = try Self.arguments(from: chars, openParen: index, location: location)
            sites.append(CallSite(
                location: location,
                arguments: arguments,
                dictionaries: try optionsDictionaries(
                    of: arguments, in: stripped, chars: chars, callAt: index,
                    location: location)))
        }
        return sites
    }

    /// The top-level arguments of a call, whitespace-normalized.
    private static func arguments(
        from chars: [Character], openParen: Int, location: String
    ) throws -> [String] {
        var depth = 0
        var current = ""
        var found: [String] = []
        var index = openParen
        while index < chars.count {
            let character = chars[index]
            if character == "(" || character == "[" || character == "{" {
                depth += 1
                if depth == 1 {
                    index += 1
                    continue
                }
            } else if character == ")" || character == "]" || character == "}" {
                depth -= 1
                if depth == 0 {
                    found.append(current)
                    return found.map(normalized)
                }
            } else if character == ",", depth == 1 {
                found.append(current)
                current = ""
                index += 1
                continue
            }
            current.append(character)
            index += 1
        }
        throw ScanError.unbalanced(location: location)
    }

    /// The dictionary literal(s) a call's options argument reaches.
    private static func optionsDictionaries(
        of arguments: [String], in stripped: String, chars: [Character], callAt: Int,
        location: String
    ) throws -> [String] {
        guard arguments.count >= 2 else {
            throw ScanError.tooFewArguments(location: location, count: arguments.count)
        }
        let expression = arguments[1].trimmingCharacters(in: .whitespaces)

        // A literal written into the call. Any trailing `as CFDictionary`
        // is past the closing bracket, so the literal is read by balance
        // rather than by cutting at the first ` as `, which sits INSIDE it
        // (`kSecImportToMemoryOnly as String: …`).
        if expression.hasPrefix("[") {
            guard let literal = balanced(Array(expression), from: 0) else {
                throw ScanError.unbalanced(location: location)
            }
            // Whatever follows the literal can put the flag back — or take
            // it away. `[flag: true].merging(extra) { _, new in new }` is
            // a truthy literal that reaches the call as whatever `extra`
            // says, and reading the literal and stopping cleared exactly
            // that. A cast is the only inert tail.
            let tail = String(expression.dropFirst(literal.count))
                .trimmingCharacters(in: .whitespaces)
            guard tail.isEmpty || tail.range(
                of: "^as[?!]?\\s+[A-Za-z_][A-Za-z0-9_.]*$", options: .regularExpression) != nil
            else {
                throw ScanError.unreadableOptions(location: location, expression: expression)
            }
            return [literal]
        }

        // Otherwise a name, possibly cast: `options as CFDictionary`. A
        // name cannot contain ` as `, so the first one ends it.
        var name = expression
        if let cast = name.range(of: " as ") { name = String(name[..<cast.lowerBound]) }
        name = name.trimmingCharacters(in: .whitespaces)
        guard name.range(
            of: "^[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*$",
            options: .regularExpression) != nil
        else {
            throw ScanError.unreadableOptions(location: location, expression: expression)
        }
        let simpleName = name.split(separator: ".").last.map(String.init) ?? name

        let declarations = try dictionaryLiterals(assignedTo: simpleName, in: stripped)
        guard !declarations.isEmpty else {
            throw ScanError.optionsNotFound(location: location, name: simpleName)
        }
        // Only the literals whose scope is still open at the call. A name
        // resolved file-wide let a careful `options` in one function clear
        // a careless `options` parameter in another — planted, and cleared,
        // by a scan that had no notion of scope at all.
        let governing = declarations.filter {
            scopeIsOpen(from: $0.start, at: callAt, in: chars)
        }
        guard !governing.isEmpty else {
            throw ScanError.optionsOutOfScope(location: location, name: simpleName)
        }
        if let use = try unaccountedUse(of: simpleName, in: stripped) {
            throw ScanError.optionsTouchedElsewhere(
                location: location, name: simpleName, use: use)
        }
        return governing.map(\.text)
    }

    /// Whether the brace scope a literal sits in is still open at the call
    /// — the cheapest reading of "this binding could be the one that
    /// reaches there". A `}` that closes past the literal's own depth
    /// before the call is that scope ending, and a binding whose scope has
    /// ended is a binding this scan must not read.
    private static func scopeIsOpen(from start: Int, at call: Int, in chars: [Character]) -> Bool {
        guard start < call else { return false }
        var depth = 0
        for index in start..<call {
            if chars[index] == "{" { depth += 1 }
            if chars[index] == "}" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return true
    }

    /// Every way of reaching a name that this scan cannot fold into "it is
    /// the literal it was assigned", as a pattern and the words for it.
    ///
    /// Counted in the pass that writes this sentence: four here, plus the
    /// plain assignment handled separately below because whether it is
    /// accounted for depends on what follows the `=`. Each was planted
    /// against the scan and is fixtured in `theScanRefusesWhatItCannotRead`.
    private static let unaccountedUsePatterns: [(pattern: String, what: String)] = [
        (#"(?<![A-Za-z0-9_])NAME\s*\["#, "a subscript"),
        (#"(?<![A-Za-z0-9_])NAME\s*\."#, "a member access"),
        (#"&\s*NAME(?![A-Za-z0-9_])"#, "an `inout` argument"),
        (#"(?<![A-Za-z0-9_])NAME\s*(?::[^=\n]*)?[-+*/%|&^]="#, "a compound assignment"),
    ]

    /// The first use of `name` in one file that this scan cannot account
    /// for, or `nil` when the name is only ever declared and read.
    ///
    /// This is what makes the reading of a dictionary literal mean
    /// anything. `var options = [flag: true]` followed by
    /// `options[flag] = kCFBooleanFalse` — or `removeValue(forKey:)`, or a
    /// merge helper, or `options = somethingElse` — leaves a literal in
    /// the file that says the opposite of what reaches the call. Both
    /// shapes were planted against the earlier version of this scan and
    /// both were cleared, which is why the verdict here is "stop", not
    /// "read the literal anyway".
    private static func unaccountedUse(of name: String, in stripped: String) throws -> String? {
        for (pattern, what) in unaccountedUsePatterns {
            let regex = try NSRegularExpression(
                pattern: pattern.replacingOccurrences(of: "NAME", with: name))
            let range = NSRange(stripped.startIndex..., in: stripped)
            if regex.firstMatch(in: stripped, range: range) != nil { return what }
        }

        // A plain assignment is accounted for only when what follows is a
        // dictionary literal — that is the one shape `dictionaryLiterals`
        // reads. `options = elsewhere`, `options = base.merging(…)`: not.
        let assignment = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])\#(name)\s*(?::[^=\n]*)?=(?!=)"#)
        let chars = Array(stripped)
        let range = NSRange(stripped.startIndex..., in: stripped)
        for match in assignment.matches(in: stripped, range: range) {
            guard let matchRange = Range(match.range, in: stripped) else { continue }
            var index = stripped.distance(from: stripped.startIndex, to: matchRange.upperBound)
            while index < chars.count, chars[index] == " " || chars[index] == "\n"
                || chars[index] == "\t"
            {
                index += 1
            }
            guard index < chars.count, chars[index] == "[" else {
                return "an assignment of something other than a dictionary literal"
            }
        }
        return nil
    }

    /// Every dictionary literal assigned to `name` in one file — `let`,
    /// `var` or a plain reassignment alike, with or without a type
    /// annotation.
    private static func dictionaryLiterals(
        assignedTo name: String, in stripped: String
    ) throws -> [(start: Int, text: String)] {
        let regex = try NSRegularExpression(
            pattern: "(?<![A-Za-z0-9_])\(name)\\s*(?::[^=\\n]*)?=\\s*\\[")
        let range = NSRange(stripped.startIndex..., in: stripped)
        let chars = Array(stripped)
        return regex.matches(in: stripped, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: stripped) else { return nil }
            let end = stripped.distance(from: stripped.startIndex, to: matchRange.upperBound)
            return balanced(chars, from: end - 1).map { (end - 1, $0) }
        }
    }

    /// The bracketed run starting at `open`, brackets balanced.
    private static func balanced(_ chars: [Character], from open: Int) -> String? {
        var depth = 0
        var index = open
        var text = ""
        while index < chars.count {
            let character = chars[index]
            text.append(character)
            if character == "[" { depth += 1 }
            if character == "]" {
                depth -= 1
                if depth == 0 { return text }
            }
            index += 1
        }
        return nil
    }

    /// The entries directly inside a dictionary literal's outer brackets,
    /// each split into key and value at its own top-level colon.
    ///
    /// Depth is the whole point. An entry whose VALUE is itself a
    /// dictionary is one entry here, not several, and the flag inside it
    /// is not a key of this literal.
    static func topLevelEntries(of dictionary: String) throws -> [(key: String, value: String)] {
        let chars = Array(dictionary)
        guard let start = chars.firstIndex(of: "[") else { return [] }
        var runs: [String] = []
        var current = ""
        var depth = 0
        var index = start
        var closed = false
        while index < chars.count {
            let character = chars[index]
            if character == "[" || character == "(" || character == "{" {
                depth += 1
                if depth == 1 {
                    index += 1
                    continue
                }
            } else if character == "]" || character == ")" || character == "}" {
                depth -= 1
                if depth == 0 {
                    runs.append(current)
                    closed = true
                    break
                }
            } else if character == ",", depth == 1 {
                runs.append(current)
                current = ""
                index += 1
                continue
            }
            current.append(character)
            index += 1
        }
        guard closed else { throw ScanError.unbalancedDictionary(dictionary: dictionary) }

        return runs.compactMap { run in
            var depth = 0
            for (offset, character) in run.enumerated() {
                if character == "(" || character == "[" || character == "{" { depth += 1 }
                if character == ")" || character == "]" || character == "}" { depth -= 1 }
                guard character == ":", depth == 0 else { continue }
                let colon = run.index(run.startIndex, offsetBy: offset)
                return (normalized(run[..<colon]), normalized(run[run.index(after: colon)...]))
            }
            // No top-level colon: an array element, or the empty run a
            // trailing comma leaves behind. Neither is a key mapped to a
            // value. (`[:]` does have a colon, and yields one entry whose
            // key and value are both empty — which names no flag.)
            return nil
        }
    }

    /// A key with any `as` cast dropped — `kSecImportToMemoryOnly as
    /// String` and `kSecImportToMemoryOnly` are the same key.
    private static func keyName(_ key: String) -> String {
        var text = key
        if let cast = text.range(of: " as ") { text = String(text[..<cast.lowerBound]) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// What the flag is mapped to as a TOP-LEVEL key of one dictionary
    /// literal, or `nil` when the literal does not carry it there.
    ///
    /// Top-level and spelled exactly, both deliberately.
    /// `SecPKCS12Import` reads the top level of the dictionary it is
    /// handed, so `kSecImportExportAccess as String: [kSecImportToMemoryOnly
    /// as String: kCFBooleanTrue]` sets nothing — and a scan that searched
    /// the literal's whole text for the flag name cleared exactly that,
    /// for a call that writes to the default keychain. A key that merely
    /// contains the flag inside a larger expression (a ternary, a call) is
    /// likewise not read: it comes back `nil`, which is an offender, which
    /// fails.
    static func memoryOnlyValue(in dictionary: String) throws -> String? {
        for (key, value) in try topLevelEntries(of: dictionary)
        where keyName(key) == memoryOnlyFlagName {
            return value
        }
        return nil
    }

    /// Whether a value means "yes". A cast is dropped (`kCFBooleanTrue as
    /// Any`); everything else has to be one of the accepted spellings.
    static func isTruthy(_ value: String) -> Bool {
        var text = value
        if let cast = text.range(of: " as ") { text = String(text[..<cast.lowerBound]) }
        return truthySpellings.contains(text.trimmingCharacters(in: .whitespaces))
    }

    private static func allCallSites() throws -> [CallSite] {
        try candidateFiles().flatMap { url in
            try callSites(
                inSource: try String(contentsOf: url, encoding: .utf8),
                file: relativePath(of: url))
        }
    }

    // MARK: - The property

    /// The check this suite exists for, with its own floor beside it.
    @Test func everyPKCS12ImportKeepsItsItemsOutOfTheKeychain() throws {
        let sites = try Self.allCallSites()
        var offenders: [String] = []
        for site in sites {
            for dictionary in site.dictionaries {
                guard let value = try Self.memoryOnlyValue(in: dictionary) else {
                    offenders.append(
                        "\(site.location): options carry no \(Self.memoryOnlyFlagName)")
                    continue
                }
                if !Self.isTruthy(value) {
                    offenders.append(
                        "\(site.location): \(Self.memoryOnlyFlagName) is `\(value)`")
                }
            }
        }

        #expect(!sites.isEmpty, """
            no `\(Self.importFunctionName)` call found under Tests/ — see \
            `theScanReachesTheImportSite`. This check has nothing to judge, which is not the \
            same as having judged something.
            """)
        #expect(offenders.isEmpty, """
            PKCS#12 import(s) under Tests/ that do not keep their items in memory:
            \(offenders.joined(separator: "\n"))

            Without `\(Self.memoryOnlyFlagName)` set to true, \(Self.importFunctionName) imports \
            the key and certificate into the default keychain — the login keychain of whoever \
            ran the tests, on every plain `swift test`, with no prompt and no failure. The test \
            suite must leave no trace outside its own temporary directories.
            """)
    }

    /// The positive half. Every floor here is a claim that the scan still
    /// reaches its subject; without them the check above passes loudest
    /// when it sees nothing at all.
    @Test func theScanReachesTheImportSite() throws {
        let roots = try Self.testRoots()
        #expect(roots.count >= 2, """
            only \(roots.count) test root(s) derived from Tests/ and Package.swift — the \
            derivation is not reading the package it thinks it is.
            """)

        // The manifest half, pinned on its own. `roots` is a union, and
        // the disk half alone already satisfies the floor above — so a
        // manifest regex that stopped matching (a reformat, a macro, a
        // moved manifest) would be exactly the condition that floor cannot
        // report. Every root the manifest declares must also be a real
        // directory: a test target whose sources are somewhere this walk
        // does not follow is a target this suite does not judge.
        let declared = try Self.manifestTestRoots()
        #expect(!declared.isEmpty, """
            Package.swift declares no test target this derivation can read. The manifest half \
            of `testRoots()` has stopped matching, and the disk half is carrying the whole \
            derivation without saying so.
            """)
        let missing = declared.filter {
            !Self.isDirectory(Self.repoRoot.appendingPathComponent($0))
        }
        #expect(missing.isEmpty, """
            Package.swift declares test target director(ies) \(missing) that do not exist. \
            Either the manifest is wrong, or this derivation is reading `path:` differently \
            from SwiftPM — and a root it drops is a root it never reports on.
            """)

        // Not a round number: every `.swift` sitting directly in a root,
        // enumerated shallowly and independently of the recursive walk.
        // A floor would be a guard against zero — 100 was cleared by the
        // core root alone, so the walk could have lost the entire AppKit
        // root (69 files, counted this pass; 254 in total) and still
        // reported that it was reaching the test sources.
        let files = Set(try Self.swiftFiles())
        for root in roots {
            let direct = try Self.fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "swift" }.map(\.standardizedFileURL)
            #expect(!direct.isEmpty, """
                \(Self.relativePath(of: root)) holds no Swift file directly. It is a test root \
                by derivation and empty by reading, which is not a combination this scan can \
                mean anything over.
                """)
            #expect(Set(direct).isSubset(of: files), """
                the walk missed \(Set(direct).subtracting(files).map(Self.relativePath).sorted()) \
                under \(Self.relativePath(of: root)) — files a plain listing of that directory \
                finds. The scan is reporting on less than it names.
                """)
        }
        #expect(files.contains(Self.ownFile), """
            the walk does not reach this file, so excluding it excludes nothing and the \
            exclusion has stopped meaning what its comment says.
            """)

        let candidates = try Self.candidateFiles()
        #expect(!candidates.isEmpty, """
            no file under Tests/ mentions `\(Self.importFunctionName)` any more. Either the \
            import is gone — in which case delete this suite deliberately — or it moved \
            somewhere this walk does not reach, and the check beside this one is judging \
            nothing.
            """)

        let sites = try Self.allCallSites()
        #expect(!sites.isEmpty, """
            \(candidates.count) file(s) mention `\(Self.importFunctionName)` but no call site \
            was parsed out of any of them. The scan matches the word and not the call, so the \
            keychain check is passing over an empty list.
            """)
    }

    // MARK: - The scan, on the cases that make it a scan

    /// Discrimination: the guarded shapes must pass and the unguarded ones
    /// must be named. Fixtures rather than the real file, because the
    /// shapes that must FAIL cannot exist anywhere in the tree — and
    /// because these go on proving the scan discriminates after the real
    /// file has been rewritten.
    @Test func theScanTellsAGuardedImportFromAnUnguardedOne() throws {
        let sites = try Self.callSites(inSource: """
            // SecPKCS12Import(bundle as CFData, careless as CFDictionary, &out)
            let prose = "SecPKCS12Import(bundle as CFData, careless as CFDictionary, &out)"
            let guarded: [String: Any] = [
                kSecImportExportPassphrase as String: passphrase,
                kSecImportToMemoryOnly as String: kCFBooleanTrue as Any,
            ]
            let careless: [String: Any] = [kSecImportExportPassphrase as String: passphrase]
            let refused: [String: Any] = [kSecImportToMemoryOnly as String: kCFBooleanFalse as Any]
            let nested: [String: Any] = [
                kSecImportExportAccess as String:
                    [kSecImportToMemoryOnly as String: kCFBooleanTrue as Any],
            ]
            _ = SecPKCS12Import(bundle as CFData, guarded as CFDictionary, &out)
            _ = SecPKCS12Import(bundle as CFData, careless as CFDictionary, &out)
            _ = SecPKCS12Import(bundle as CFData, refused as CFDictionary, &out)
            _ = SecPKCS12Import(bundle as CFData, nested as CFDictionary, &out)
            _ = SecPKCS12Import(
                bundle as CFData,
                [kSecImportToMemoryOnly as String: true] as CFDictionary,
                &out)
            """, file: "fixture")

        #expect(sites.count == 5, """
            expected the five calls in code and neither the commented-out one nor the quoted \
            one: \(sites.map(\.location))
            """)

        var verdicts: [String] = []
        for site in sites {
            let values = try site.dictionaries.map { try Self.memoryOnlyValue(in: $0) }
            verdicts.append(values.allSatisfy { $0.map(Self.isTruthy) == true } ? "ok" : "offender")
        }
        #expect(verdicts == ["ok", "offender", "offender", "offender", "ok"], """
            the flag set to true — through a named dictionary or written into the call — must \
            pass; a missing flag, a false one, and one that sits inside another entry's value \
            instead of at the top level must not: \(verdicts)
            """)
    }

    /// Fail-closed: every shape the scan cannot resolve has to stop it. A
    /// call whose options it cannot read is not a call it has cleared.
    ///
    /// The last five are the ones that matter, and none of them was in the
    /// author's first enumeration: a review planted a truthy literal
    /// followed by a subscript that overwrote the flag, and the scan
    /// cleared the call. Every way of touching the name after its literal
    /// now stops the scan, whether or not the flag was true when it was
    /// written — which is why `guarded` below carries the flag and is
    /// still refused.
    @Test func theScanRefusesWhatItCannotRead() {
        let guarded = "let options: [String: Any] = [kSecImportToMemoryOnly as String: true]"
        let call = "_ = SecPKCS12Import(data, options as CFDictionary, &out)"
        let unreadable = [
            // Options built by a function the scan cannot follow.
            "_ = SecPKCS12Import(data, makeOptions() as CFDictionary, &out)",
            // A name assigned no dictionary literal in this file.
            "_ = SecPKCS12Import(data, elsewhere as CFDictionary, &out)",
            // A reference that could be called anywhere, with anything.
            "let importer = SecPKCS12Import",
            // Assembled by subscript from an empty literal.
            """
            var options: [String: Any] = [:]
            options[kSecImportToMemoryOnly as String] = kCFBooleanTrue
            \(call)
            """,
            // The flag written true, then overwritten.
            """
            \(guarded)
            options[kSecImportToMemoryOnly as String] = kCFBooleanFalse
            \(call)
            """,
            // The flag written true, then removed.
            """
            \(guarded)
            options.removeValue(forKey: kSecImportToMemoryOnly as String)
            \(call)
            """,
            // The flag written true, then the whole dictionary replaced by
            // something that is not a literal.
            """
            \(guarded)
            options = elsewhere
            \(call)
            """,
            // The flag written true, then handed to something that can
            // change it in place.
            """
            \(guarded)
            mutate(&options)
            \(call)
            """,
            // A truthy literal written into the call, with a merge chained
            // onto it that can put anything back.
            """
            _ = SecPKCS12Import(
                data,
                [kSecImportToMemoryOnly as String: true]
                    .merging(extra) { _, new in new } as CFDictionary,
                &out)
            """,
            // A careful `options` in one scope and a careless one in
            // another. Neither of the last two was in this suite's own
            // enumeration; both were planted by a reader afterwards and
            // both were cleared.
            """
            func careful() {
                \(guarded)
                \(call)
            }
            func careless(options: [String: Any]) {
                \(call)
            }
            """,
        ]
        for source in unreadable {
            #expect(throws: (any Error).self, "\(source)") {
                try Self.callSites(inSource: source, file: "fixture")
            }
        }
    }

    /// The compile-time anchor. The scan looks for two words; these are the
    /// symbols those words are supposed to name. Referencing both here —
    /// and calling neither — means an SDK that renames or removes either
    /// one fails this target's build, loudly, instead of leaving a scan
    /// searching for a word that no longer occurs and reporting that it
    /// found no violations.
    @Test func theGuardedSymbolsAreTheOnesTheSDKStillHas() {
        let importer = SecPKCS12Import
        let flag = kSecImportToMemoryOnly as String
        #expect(!String(describing: importer).isEmpty)
        #expect(!flag.isEmpty)
    }
}
