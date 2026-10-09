import Testing
import Foundation
@testable import macSCPCore

@Suite(.timeLimit(.minutes(1)))
struct ArchivePlanTests {
    private func file(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/d/" + name, kind: .file)
    }
    private func folder(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/d/" + name, kind: .directory)
    }
    private func names(of plan: ArchivePlan) -> [String] {
        guard let stdin = plan.stdin else { return [] }
        let separator: UInt8 = plan.tool == "zip" ? 0x0A : 0x00
        return stdin.split(separator: separator).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func zipTakesItsNamesOnStdinOnePerLine() throws {
        let plan = try ArchivePlan.compress(
            .zip, selection: [folder("d"), file("top file")],
            workingDirectory: "/d", archiveName: "out.zip")
        #expect(plan.tool == "zip")
        #expect(plan.operation == .compress(.zip))
        #expect(plan.words == [.flag("-r"), .flag("-@"), .operand("./out.zip")])
        #expect(names(of: plan) == ["d", "top file"])
    }

    @Test func tarTakesItsNamesOnStdinNulSeparated() throws {
        let plan = try ArchivePlan.compress(
            .tarGz, selection: [folder("d"), file("top file")],
            workingDirectory: "/d", archiveName: "out.tar.gz")
        #expect(plan.tool == "tar")
        #expect(plan.words == [
            .flag("--null"), .flag("-T"), .flag("-"), .flag("-czf"), .operand("./out.tar.gz"),
        ])
        #expect(names(of: plan) == ["d", "top file"])
        // Exact bytes: `names(of:)` splits and so drops an empty tail, which
        // would hide a missing trailing NUL.
        #expect(plan.stdin == Data("d\0top file\0".utf8))
    }

    /// The selection reaches the tool as BYTES, never as a word, so nothing
    /// in it can be read as syntax. This is the property the whole design
    /// exists for; it is asserted on the plan, where it is checkable without
    /// a server.
    @Test(arguments: ["$(reboot)", "a'b", "a b", "`id`", "-rf", "a;b", "a|b", "a\\b", "ä€🙂"])
    func aHostileNameNeverBecomesAWord(hostile: String) throws {
        let plan = try ArchivePlan.compress(
            .zip, selection: [file(hostile)],
            workingDirectory: "/d", archiveName: "out.zip")
        let operands = plan.words.compactMap { word -> String? in
            if case .operand(let value) = word { return value }
            return nil
        }
        #expect(operands == ["./out.zip"])
        #expect(names(of: plan) == [hostile])
    }

    @Test func zipRefusesANameHoldingANewline() {
        #expect(throws: ArchiveRefusal.newlineInNameUnsupportedByZip(name: "two\nlines")) {
            try ArchivePlan.compress(
                .zip, selection: [file("two\nlines")],
                workingDirectory: "/d", archiveName: "out.zip")
        }
    }

    /// The same name is fine for the NUL-separated paths, which is the whole
    /// reason the refusal above is per-format and not per-feature. A
    /// positive beside the negative, as this project requires.
    @Test(arguments: [ArchiveFormat.tarGz])
    func aNameHoldingANewlineIsFineWhereTheSeparatorIsNul(format: ArchiveFormat) throws {
        let plan = try ArchivePlan.compress(
            format, selection: [file("two\nlines")],
            workingDirectory: "/d", archiveName: "out." + format.fileExtension)
        #expect(names(of: plan) == ["two\nlines"])
    }

    @Test func gzKeepsItsInputAndTakesNoStdin() throws {
        let plan = try ArchivePlan.compress(
            .gz, selection: [file("big.log")],
            workingDirectory: "/d", archiveName: "big.log.gz")
        #expect(plan.tool == "gzip")
        #expect(plan.words == [.flag("-k"), .flag("--"), .operand("big.log")])
        #expect(plan.stdin == nil)
    }

    @Test func extractingIntoThisFolderSkipsWhatIsAlreadyThere() throws {
        let plan = try ArchivePlan.extract(
            file("ar.zip"), format: .zip, workingDirectory: "/d", into: .thisFolder,
            tarSkipExisting: .keepOldFiles)
        #expect(plan.tool == "unzip")
        #expect(plan.words == [.flag("-n"), .flag("-q"), .operand("./ar.zip")])
    }

    @Test func extractingIntoASubfolderNamesItAsTheDestination() throws {
        let plan = try ArchivePlan.extract(
            file("ar.zip"), format: .zip, workingDirectory: "/d",
            into: .subfolder("ar 2"), tarSkipExisting: .keepOldFiles)
        #expect(plan.words == [
            .flag("-n"), .flag("-q"), .operand("./ar.zip"), .flag("-d"), .operand("./ar 2"),
        ])
    }

    /// The flavour decides the flag, and both answers are pinned: a
    /// positive for each, so neither branch can go quietly wrong.
    @Test(arguments: [
        (TarSkipExisting.keepOldFiles, "--keep-old-files"),
        (TarSkipExisting.skipOldFiles, "--skip-old-files"),
    ])
    func extractingATarballSkipsExistingWithTheFlagThatFlavourTakes(
        flavour: TarSkipExisting, flag: String
    ) throws {
        let plan = try ArchivePlan.extract(
            file("ar.tar.gz"), format: .tarGz, workingDirectory: "/d", into: .thisFolder,
            tarSkipExisting: flavour)
        #expect(plan.tool == "tar")
        #expect(plan.words == [
            .flag(flag), .flag("-xzf"), .operand("./ar.tar.gz"),
        ])
    }

    /// A user-supplied archive name can begin with a dash, and this project
    /// has not measured `--` against `unzip` or `tar`. The `./` prefix makes
    /// a leading dash harmless without claiming support for a terminator
    /// that was never tested.
    @Test func aUserSuppliedArchiveNameIsPrefixedSoALeadingDashIsNotAnOption() throws {
        let plan = try ArchivePlan.extract(
            file("-rf.zip"), format: .zip, workingDirectory: "/d", into: .thisFolder,
            tarSkipExisting: .keepOldFiles)
        #expect(plan.words.contains(.operand("./-rf.zip")))
    }

    @Test func theLocalInvocationIsArgvWithNoQuotingAndNoShell() throws {
        let plan = try ArchivePlan.compress(
            .zip, selection: [file("a'b")],
            workingDirectory: "/d", archiveName: "out.zip")
        let invocation = try plan.localInvocation(resolvingToolWith: { "/usr/bin/" + $0 })
        #expect(invocation.executable == URL(fileURLWithPath: "/usr/bin/zip"))
        #expect(invocation.arguments == ["-r", "-@", "./out.zip"])
        #expect(invocation.currentDirectory == URL(fileURLWithPath: "/d"))
        #expect(invocation.stdin == Data("a'b\n".utf8))
    }

    @Test func extractingATarKeepsOldFilesAndDoesNotGunzip() throws {
        let plan = try ArchivePlan.extract(
            file("ar.tar"), format: .tar, workingDirectory: "/d", into: .thisFolder,
            tarSkipExisting: .keepOldFiles)
        #expect(plan.tool == "tar")
        #expect(plan.words == [
            .flag("--keep-old-files"), .flag("-xf"), .operand("./ar.tar"),
        ])
    }

    @Test func extractingATarballIntoASubfolderNamesItWithC() throws {
        let plan = try ArchivePlan.extract(
            file("ar.tar.gz"), format: .tarGz, workingDirectory: "/d",
            into: .subfolder("ar 2"), tarSkipExisting: .keepOldFiles)
        #expect(plan.operation == .extract(.tarGz))
        #expect(plan.words == [
            .flag("--keep-old-files"), .flag("-xzf"), .operand("./ar.tar.gz"),
            .flag("-C"), .operand("./ar 2"),
        ])
    }

    @Test func extractingAGzKeepsTheArchiveAndTerminatesOptions() throws {
        let plan = try ArchivePlan.extract(
            file("f.gz"), format: .gz, workingDirectory: "/d", into: .thisFolder,
            tarSkipExisting: .keepOldFiles)
        #expect(plan.tool == "gunzip")
        #expect(plan.words == [.flag("-k"), .flag("--"), .operand("./f.gz")])
        #expect(plan.stdin == nil)
    }

    @Test func extractingAGzIntoASubfolderIsRefused() {
        #expect(throws: ArchiveRefusal.gzExtractsIntoThisFolderOnly) {
            try ArchivePlan.extract(
                file("f.gz"), format: .gz, workingDirectory: "/d",
                into: .subfolder("f 2"), tarSkipExisting: .keepOldFiles)
        }
    }

    /// `compress` re-checks what `ArchiveNaming.proposedName` already checks,
    /// deliberately; these pin the duplicates, which Task 1's tests do not
    /// reach.
    @Test func compressRefusesAnEmptySelection() {
        #expect(throws: ArchiveRefusal.emptySelection) {
            try ArchivePlan.compress(
                .zip, selection: [], workingDirectory: "/d", archiveName: "out.zip")
        }
    }

    @Test func gzCompressRefusesTwoFiles() {
        #expect(throws: ArchiveRefusal.gzTakesExactlyOneFile(count: 2)) {
            try ArchivePlan.compress(
                .gz, selection: [file("a"), file("b")],
                workingDirectory: "/d", archiveName: "a.gz")
        }
    }

    @Test func gzCompressRefusesAFolder() {
        #expect(throws: ArchiveRefusal.gzTakesAFileNotAFolder(name: "d")) {
            try ArchivePlan.compress(
                .gz, selection: [folder("d")],
                workingDirectory: "/d", archiveName: "d.gz")
        }
    }

    /// The archive name comes from the SELECTED item's own name
    /// (`ArchiveNaming.proposedName`), so a file called `-v` would put a
    /// leading dash on the command line. Measured 2026-10-08:
    /// `zip -q -r -@ '-v2.zip'` answered "Invalid command arguments (short
    /// option '.' not supported)" and exited 16, while the `./` form
    /// created the archive. tar accepts both, so the prefix is one rule
    /// rather than a per-tool exception.
    @Test(arguments: [ArchiveFormat.zip, ArchiveFormat.tarGz])
    func anArchiveNameBeginningWithADashIsNotAnOption(format: ArchiveFormat) throws {
        let plan = try ArchivePlan.compress(
            format, selection: [file("x")], workingDirectory: "/d",
            archiveName: "-v." + format.fileExtension)
        #expect(plan.words.contains(.operand("./-v." + format.fileExtension)))
    }
}
