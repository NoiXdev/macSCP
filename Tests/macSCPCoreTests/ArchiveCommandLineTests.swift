import Testing
import Foundation
@testable import macSCPCore

@Suite(.timeLimit(.minutes(1)))
struct ArchiveCommandLineTests {
    private func file(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/d/" + name, kind: .file)
    }

    @Test func theLineEntersTheWorkingDirectoryAndRunsTheTool() throws {
        let plan = try ArchivePlan.compress(
            .zip, selection: [file("a")], workingDirectory: "/srv/data",
            archiveName: "out.zip")
        #expect(plan.remoteCommandLine().text == "cd '/srv/data' && zip -r -@ './out.zip'")
    }

    @Test func everyFlagIsUnquotedAndEveryOperandIsQuoted() throws {
        let plan = try ArchivePlan.compress(
            .tarGz, selection: [file("a")], workingDirectory: "/d",
            archiveName: "out.tar.gz")
        #expect(
            plan.remoteCommandLine().text
                == "cd '/d' && tar --null -T - -czf './out.tar.gz'")
    }

    /// The archive name is the one user-controlled operand this suite
    /// hammers. This checks ROUTING: the name reaches the line through
    /// `PosixQuoting.singleQuoted`. That the helper's result is one shell
    /// word is pinned where the helper lives, in `PosixQuotingTests` and
    /// `ShellQuotingExecutionTests`. The value is built into a constant and
    /// the Bool computed before the expectation, because `#expect` prints
    /// the SOURCE TEXT of what it checks and a failure must not reproduce
    /// the payload.
    @Test(arguments: [
        "a'b", "$(reboot)", "`id`", "a;rm -rf /", "a b", "a|b", "a\\b", "a\nb", "ä€🙂",
    ])
    func ahostileArchiveNameIsRoutedThroughTheQuotingHelper(hostile: String) throws {
        let plan = try ArchivePlan.compress(
            .tarGz, selection: [file("x")], workingDirectory: "/d",
            archiveName: hostile)
        let expected = "cd '/d' && tar --null -T - -czf "
            + PosixQuoting.singleQuoted("./" + hostile)
        let matches = plan.remoteCommandLine().text == expected
        #expect(matches)
    }

    /// The working directory is the one user-controlled word on the line
    /// that is not an `.operand`, and it is quoted by the same helper. A
    /// hand-rolled `"cd '" + workingDirectory + "'"` would pass every other
    /// case in this suite and break on a directory holding an apostrophe.
    @Test(arguments: [
        "/home/o'brien", "/d/$(reboot)", "/d/`id`", "/d/a b", "/d/a;b", "/d/ä€🙂",
    ])
    func ahostileWorkingDirectoryIsRoutedThroughTheQuotingHelper(hostile: String) throws {
        let plan = try ArchivePlan.compress(
            .zip, selection: [file("x")], workingDirectory: hostile,
            archiveName: "out.zip")
        let expected = "cd " + PosixQuoting.singleQuoted(hostile)
            + " && zip -r -@ './out.zip'"
        let matches = plan.remoteCommandLine().text == expected
        #expect(matches)
    }

    /// The positive beside that negative: the quoting is REACHED at all.
    /// Without this, a rendering that dropped the operand entirely would
    /// satisfy every "no unquoted metacharacter" check above.
    @Test func theOperandIsPresentInTheLine() throws {
        let plan = try ArchivePlan.compress(
            .zip, selection: [file("x")], workingDirectory: "/d",
            archiveName: "report.zip")
        #expect(plan.remoteCommandLine().text.contains("'./report.zip'"))
    }

    /// Holds for the stdin-fed formats only (`zip`, `tar`): there the
    /// selection travels as bytes, never as a word. For `.gz` the selected
    /// name IS an operand, and `aGzSelectionIsAQuotedOperandAfterTheTerminator`
    /// covers that.
    @Test func theSelectionOfAStdinFedFormatIsNowhereInTheLine() throws {
        let plan = try ArchivePlan.compress(
            .tarGz, selection: [file("secret-looking-name")],
            workingDirectory: "/d", archiveName: "out.tar.gz")
        #expect(plan.remoteCommandLine().text.contains("secret-looking-name") == false)
    }

    @Test func aGzSelectionIsAQuotedOperandAfterTheTerminator() throws {
        let plan = try ArchivePlan.compress(
            .gz, selection: [file("n")], workingDirectory: "/d", archiveName: "n.gz")
        #expect(plan.remoteCommandLine().text == "cd '/d' && gzip -k -- 'n'")
    }

    @Test func anExtractionQuotesTheArchiveNameItWasGiven() throws {
        let plan = try ArchivePlan.extract(
            file("ar.zip"), format: .zip, workingDirectory: "/d",
            into: .subfolder("ar 2"))
        #expect(
            plan.remoteCommandLine().text
                == "cd '/d' && unzip -n -q './ar.zip' -d './ar 2'")
    }
}
