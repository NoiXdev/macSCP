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
/// ## What this guard cannot see
///
/// - **A call reached through `dlsym`** or any other runtime lookup names
///   the function nowhere in source.
/// - **An options dictionary assembled by subscript** (`options[k] = v`)
///   rather than written as a literal. The scan reads only the literal the
///   name was assigned, so a flag set afterwards is invisible to it — and
///   the call is reported as unguarded rather than cleared. Wrong for the
///   right reason: every shape this cannot read fails, none passes.
/// - **This file itself**, which is excluded for the reason given at
///   `ownFile`.
/// - **The keychain proper.** Nothing here observes what a run actually
///   wrote; it reads source. A test that deliberately writes to the
///   keychain behind `MACSCP_KEYCHAIN` is a different property, guarded
///   elsewhere.
@Suite("PKCS#12 import isolation")
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
        case unbalanced(location: String)

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
            case .unbalanced(let location):
                return """
                    \(location): unbalanced brackets around the call — the file does not parse.
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

    /// Every test root, from disk and from the manifest both — a target
    /// declared in `Package.swift` and a directory sitting under `Tests/`
    /// are each reason enough to read it.
    static func testRoots() throws -> [URL] {
        var names: Set<String> = []
        for entry in try fileManager.contentsOfDirectory(
            at: testsDirectory, includingPropertiesForKeys: [.isDirectoryKey]) where
            isDirectory(entry)
        {
            names.insert(entry.lastPathComponent)
        }
        let manifest = try String(
            contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        for name in try captures("\\.testTarget\\(\\s*name:\\s*\"([^\"]+)\"", in: manifest) {
            names.insert(name)
        }
        return names.sorted()
            .map { testsDirectory.appendingPathComponent($0) }
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
                    of: arguments, in: stripped, location: location)))
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
        of arguments: [String], in stripped: String, location: String
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
        return declarations
    }

    /// Every dictionary literal assigned to `name` in one file — `let`,
    /// `var` or a plain reassignment alike, with or without a type
    /// annotation.
    private static func dictionaryLiterals(
        assignedTo name: String, in stripped: String
    ) throws -> [String] {
        let regex = try NSRegularExpression(
            pattern: "(?<![A-Za-z0-9_])\(name)\\s*(?::[^=\\n]*)?=\\s*\\[")
        let range = NSRange(stripped.startIndex..., in: stripped)
        let chars = Array(stripped)
        return regex.matches(in: stripped, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: stripped) else { return nil }
            let end = stripped.distance(from: stripped.startIndex, to: matchRange.upperBound)
            return balanced(chars, from: end - 1)
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

    /// What the flag is mapped to inside one dictionary literal, or `nil`
    /// when the literal does not mention it at all.
    static func memoryOnlyValue(in dictionary: String) throws -> String? {
        let regex = try NSRegularExpression(
            pattern: "(?<![A-Za-z0-9_])\(memoryOnlyFlagName)(?![A-Za-z0-9_])")
        let range = NSRange(dictionary.startIndex..., in: dictionary)
        guard let match = regex.firstMatch(in: dictionary, range: range),
            let matchRange = Range(match.range, in: dictionary)
        else { return nil }

        let chars = Array(dictionary)
        var index = dictionary.distance(from: dictionary.startIndex, to: matchRange.upperBound)
        // Past an ` as String` cast on the key, to the colon that opens the
        // value. A `,` or `]` first means there is no value to read.
        while index < chars.count, chars[index] != ":", chars[index] != ",", chars[index] != "]" {
            index += 1
        }
        guard index < chars.count, chars[index] == ":" else { return "" }
        index += 1

        var depth = 0
        var value = ""
        while index < chars.count {
            let character = chars[index]
            if character == "(" || character == "[" || character == "{" { depth += 1 }
            if character == ")" || character == "}" { depth -= 1 }
            if character == "]" {
                if depth == 0 { break }
                depth -= 1
            }
            if character == ",", depth == 0 { break }
            value.append(character)
            index += 1
        }
        return normalized(value)
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

        let files = try Self.swiftFiles()
        #expect(files.count >= 100, """
            only \(files.count) Swift file(s) walked under \(roots.map(Self.relativePath)) — the \
            walk is not reaching the test sources.
            """)
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
            _ = SecPKCS12Import(bundle as CFData, guarded as CFDictionary, &out)
            _ = SecPKCS12Import(bundle as CFData, careless as CFDictionary, &out)
            _ = SecPKCS12Import(bundle as CFData, refused as CFDictionary, &out)
            _ = SecPKCS12Import(
                bundle as CFData,
                [kSecImportToMemoryOnly as String: true] as CFDictionary,
                &out)
            var assembled: [String: Any] = [:]
            assembled[kSecImportToMemoryOnly as String] = kCFBooleanTrue
            _ = SecPKCS12Import(bundle as CFData, assembled as CFDictionary, &out)
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
        #expect(verdicts == ["ok", "offender", "offender", "ok", "offender"], """
            the flag set to true — through a named dictionary or written into the call — must \
            pass; a missing flag, a false one, and one the scan cannot see because it was set \
            by subscript after the literal must not: \(verdicts)
            """)
    }

    /// Fail-closed: every shape the scan cannot resolve has to stop it. A
    /// call whose options it cannot read is not a call it has cleared.
    @Test func theScanRefusesWhatItCannotRead() {
        let unreadable = [
            // Options built by a function the scan cannot follow.
            "_ = SecPKCS12Import(data, makeOptions() as CFDictionary, &out)",
            // A name assigned no dictionary literal in this file.
            "_ = SecPKCS12Import(data, elsewhere as CFDictionary, &out)",
            // A reference that could be called anywhere, with anything.
            "let importer = SecPKCS12Import",
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
