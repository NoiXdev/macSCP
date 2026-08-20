import Foundation
import Testing

@testable import macSCPCore

/// The quoting promise, proven the only way it can be proven: by handing the
/// result to a real shell and looking at the filesystem afterwards.
///
/// Every other test in this area asserts on strings, which is an assertion
/// about what *we* think a shell does. A review round broke that assumption
/// underneath every one of them at once: an apostrophe carrying U+0308
/// COMBINING DIAERESIS is one Swift `Character` that compares unequal to
/// `"'"` and that `replacingOccurrences(of: "'")` does not find, so the
/// quoter left it unescaped and a VALUE broke out of its own single quotes.
/// `echo {{X}}` — a template every version of the gate has accepted — plus
/// such a value executed arbitrary commands. The value need not even be
/// typed by the victim: a snippet's `defaultValue` arrives through import
/// and pre-fills the prompt.
///
/// So these tests run `bash`. Each one builds a command whose payload, if it
/// escaped its quotes, would create a marker file in a fresh scratch
/// directory; the assertion is that the file is not there. A marker is the
/// one signal that cannot be argued with.
///
/// No test failure message here contains a value or a resolved command:
/// values in this suite are attack payloads, and a payload in a test log is
/// a value that left the process.
@Suite("shell quoting, executed")
struct ShellQuotingExecutionTests {
    /// `'` U+0308 — the apostrophe that is not an apostrophe to Swift.
    private static let markedQuote = "'\u{0308}"

    /// A scratch directory that exists for the duration of one test.
    private func withScratchDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-quoting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    /// Runs `command` with `bash` in `directory`, with no stdin and no
    /// inherited output, and waits for it. The exit status is ignored on
    /// purpose: a payload that fails to run and a payload that runs are both
    /// interesting only through the marker file.
    private func runInBash(_ command: String, in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    private func markerExists(_ name: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(name).path)
    }

    private func placeholder(_ name: String) -> SnippetVariable {
        SnippetVariable(
            name: name, prompt: name, kind: .freeText, placement: .placeholder,
            defaultValue: "", remembersLastValue: false)
    }

    private func environment(_ name: String) -> SnippetVariable {
        SnippetVariable(
            name: name, prompt: name, kind: .freeText, placement: .environment,
            defaultValue: "", remembersLastValue: false)
    }

    /// Critical 1, the plain case: an accepted template, a hostile value.
    ///
    /// The template needs no craft at all — it is the first example in the
    /// snippet editor's own help text. Before the fix this resolved to
    /// `echo ''̈; touch MARKER; '̈'`, where `''` is an empty word, the
    /// combining mark is literal bytes, and `;` ends the command.
    @Test func aValueWhoseQuotesCarryACombiningMarkCannotBreakOut() throws {
        let marker = "marker-placeholder"
        let value = "\(Self.markedQuote); touch \(marker); \(Self.markedQuote)"
        let variables = [placeholder("X")]
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: "echo {{X}}", variables: variables) == nil)
        let resolved = SnippetVariableSubstitution.resolve(
            command: "echo {{X}}", variables: variables, values: ["X": value])

        try withScratchDirectory { directory in
            try runInBash(resolved, in: directory)
            #expect(
                !markerExists(marker, in: directory),
                "the value escaped its single quotes and ran as a command")
        }
    }

    /// The same payload with a variation selector rather than a combining
    /// diaeresis, and with a single marked quote rather than a pair. Both
    /// executed before the fix; both are the same defect, and neither is a
    /// shape a value is checked for anywhere.
    @Test(
        "a value cannot break out however its quote is decorated",
        arguments: [
            "'\u{FE0F}; touch marker-decorated; '\u{FE0F}",
            "'\u{0300}; touch marker-decorated; '\u{0300}",
            "'\u{20E3}; touch marker-decorated ;#",
            "'\u{200D}; touch marker-decorated; '\u{200D}",
        ])
    func aDecoratedQuoteInAValueCannotBreakOut(value: String) throws {
        let variables = [placeholder("X")]
        let resolved = SnippetVariableSubstitution.resolve(
            command: "echo {{X}}", variables: variables, values: ["X": value])

        try withScratchDirectory { directory in
            try runInBash(resolved, in: directory)
            #expect(
                !markerExists("marker-decorated", in: directory),
                "the value escaped its single quotes and ran as a command")
        }
    }

    /// The `.environment` placement uses the same quoter and was affected
    /// identically — `V=''̈; touch E1; '̈' echo $V` ran the payload as its
    /// own command. The survey never sees this path (it is scoped to
    /// commands that declare a placeholder), so the quoter is the only thing
    /// standing between an imported default value and a shell here.
    @Test func anEnvironmentValueWhoseQuotesCarryACombiningMarkCannotBreakOut() throws {
        let marker = "marker-environment"
        let value = "\(Self.markedQuote); touch \(marker); \(Self.markedQuote)"
        let resolved = SnippetVariableSubstitution.resolve(
            command: "echo $V", variables: [environment("V")], values: ["V": value])

        try withScratchDirectory { directory in
            try runInBash(resolved, in: directory)
            #expect(
                !markerExists(marker, in: directory),
                "the assignment's value escaped its single quotes and ran as a command")
        }
    }

    /// The other caller of `PosixQuoting.singleQuoted`: the `ssh` line handed
    /// to an external terminal app. Host, username and key path all come from
    /// a session, and a session arrives through import too, so the same
    /// marked quotes reach the same quoter by a completely different route.
    ///
    /// The key PATH carries the payload here, because host and username are
    /// additionally screened by `SSHConnectionConfig`'s ban lists (which this
    /// pass also moved onto scalars) while the key path is only checked for
    /// being non-empty. That makes it the honest test of the quoter: nothing
    /// but quoting stands between this value and the shell.
    ///
    /// Executed against a stub `ssh` on `PATH` rather than the real one: the
    /// question is whether the shell splits the line into more than one
    /// command, not what `ssh` does with it.
    @Test func anSSHCommandLineCannotBeBrokenByAMarkedQuoteInTheKeyPath() throws {
        let marker = "marker-ssh"
        let hostile = "/keys/\(Self.markedQuote); touch \(marker); \(Self.markedQuote)"
        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim",
            auth: .privateKey(keyPath: hostile, passphrase: nil))
        let command = SSHCommandBuilder.shellCommand(for: config)

        try withScratchDirectory { directory in
            let binDirectory = directory.appendingPathComponent("bin")
            try FileManager.default.createDirectory(
                at: binDirectory, withIntermediateDirectories: true)
            let stub = binDirectory.appendingPathComponent("ssh")
            try "#!/bin/sh\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: stub.path)

            try runInBash("PATH='\(binDirectory.path)':\"$PATH\"; \(command)", in: directory)
            #expect(
                !markerExists(marker, in: directory),
                "an ssh argument escaped its single quotes and ran as a command")
        }
    }

    /// The host ban list, from the same angle: a metacharacter carrying a
    /// combining mark used to slip past a `Set<Character>` membership test.
    /// It is a second layer rather than the only one — the quoter is the
    /// first — but a second layer that can be walked through is not one.
    @Test(
        "a metacharacter carrying a combining mark does not pass the host ban list",
        arguments: ["ex\u{0027}\u{0308}ample.com", "ex\u{0024}\u{0308}ample.com",
                    "ex\u{003B}\u{0308}ample.com", "ex\u{0060}\u{0308}ample.com"])
    func aDecoratedMetacharacterIsBannedInAHost(host: String) {
        #expect(throws: (any Error).self) {
            try SSHConnectionConfig(host: host, username: "tim", auth: .password("x"))
        }
    }

    /// Critical 2 from the other side: the templates the recogniser could not
    /// see. Each one puts the placeholder inside quotes a shell honours and
    /// Swift's `Character` comparison did not, and each one created the
    /// marker before the fix. The assertion here is on the gate rather than
    /// on `bash`, because a refused template is never resolved and so never
    /// reaches a shell at all — refusal IS the protection.
    @Test(
        "a quote carrying a combining mark is seen by the recogniser",
        arguments: [
            "echo x'\u{0308}{{X}}'\u{0308}",
            "echo x\"\u{0308}{{X}}\"\u{0308}",
            "echo x'\u{FE0F}{{X}}'\u{FE0F}",
            "echo x'\u{200D}{{X}}'\u{200D}",
            "echo x'\u{0300}{{X}}'\u{0300}",
            "echo x'\u{20E3}{{X}}'\u{20E3}",
            "echo x'\u{1AB0}{{X}}'\u{1AB0}",
            "echo '\u{0308}{{X}}'\u{0308} end",
            "echo x'\u{0308}{{X}}'\u{0308}y'\u{0308}'\u{0308}",
            "git commit -m'\u{0308}{{X}}'\u{0308}",
            "curl -H Authorization:Bearer'\u{0308}{{X}}'\u{0308} https://example.invalid",
        ])
    func aMarkedQuoteIsNotInvisibleToTheGate(command: String) {
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: command, variables: [placeholder("X")]) != nil,
            "a placeholder a shell reads as quoted was accepted as an argument")
    }

    /// And the refusal above is load-bearing, not cosmetic: resolved anyway
    /// and executed, that template DOES run the payload. The template's own
    /// quotes close around the value's quotes, so `$(…)` lands unquoted —
    /// quoting cannot save this one, which is exactly why the recogniser has
    /// to see the marked quote and refuse.
    ///
    /// Asserting that a marker IS created is the unusual direction, and it
    /// is the point: if a later change made this shape inert, the corpus
    /// entry above would be pinning a refusal that no longer defends
    /// anything, and this test says so instead of staying quietly green.
    @Test func theRefusedMarkedQuoteTemplateWouldOtherwiseExecute() throws {
        let marker = "marker-marked-template"
        let command = "echo x'\u{0308}{{X}}'\u{0308}"
        let resolved = SnippetVariableSubstitution.resolve(
            command: command, variables: [placeholder("X")],
            values: ["X": "$(touch \(marker))"])

        try withScratchDirectory { directory in
            try runInBash(resolved, in: directory)
            #expect(
                markerExists(marker, in: directory),
                """
                this template no longer executes its payload; the refusal it is pinned \
                against may now be defending nothing
                """)
        }
    }
}
