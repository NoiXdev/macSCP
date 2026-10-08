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
        #expect(plan.words == [.flag("-r"), .flag("-@"), .operand("out.zip")])
        #expect(names(of: plan) == ["d", "top file"])
    }

    @Test func tarTakesItsNamesOnStdinNulSeparated() throws {
        let plan = try ArchivePlan.compress(
            .tarGz, selection: [folder("d"), file("top file")],
            workingDirectory: "/d", archiveName: "out.tar.gz")
        #expect(plan.tool == "tar")
        #expect(plan.words == [
            .flag("--null"), .flag("-T"), .flag("-"), .flag("-czf"), .operand("out.tar.gz"),
        ])
        #expect(names(of: plan) == ["d", "top file"])
    }

    /// The selection reaches the tool as BYTES, never as a word, so nothing
    /// in it can be read as syntax. This is the property the whole design
    /// exists for; it is asserted on the plan, where it is checkable without
    /// a server.
    @Test(arguments: ["$(reboot)", "a'b", "a b", "`id`", "-rf", "a;b", "a|b", "a\\b", "ä€🙂"])
    func ahostileNameNeverBecomesAWord(hostile: String) throws {
        let plan = try ArchivePlan.compress(
            .zip, selection: [file(hostile)],
            workingDirectory: "/d", archiveName: "out.zip")
        let operands = plan.words.compactMap { word -> String? in
            if case .operand(let value) = word { return value }
            return nil
        }
        #expect(operands == ["out.zip"])
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
            file("ar.zip"), format: .zip, workingDirectory: "/d", into: .thisFolder)
        #expect(plan.tool == "unzip")
        #expect(plan.words == [.flag("-n"), .flag("-q"), .operand("./ar.zip")])
    }

    @Test func extractingIntoASubfolderNamesItAsTheDestination() throws {
        let plan = try ArchivePlan.extract(
            file("ar.zip"), format: .zip, workingDirectory: "/d",
            into: .subfolder("ar 2"))
        #expect(plan.words == [
            .flag("-n"), .flag("-q"), .operand("./ar.zip"), .flag("-d"), .operand("./ar 2"),
        ])
    }

    @Test func extractingATarballKeepsOldFiles() throws {
        let plan = try ArchivePlan.extract(
            file("ar.tar.gz"), format: .tarGz, workingDirectory: "/d", into: .thisFolder)
        #expect(plan.tool == "tar")
        #expect(plan.words == [
            .flag("--keep-old-files"), .flag("-xzf"), .operand("./ar.tar.gz"),
        ])
    }

    /// A user-supplied archive name can begin with a dash, and this project
    /// has not measured `--` against `unzip` or `tar`. The `./` prefix makes
    /// a leading dash harmless without claiming support for a terminator
    /// that was never tested.
    @Test func auserSuppliedArchiveNameIsPrefixedSoALeadingDashIsNotAnOption() throws {
        let plan = try ArchivePlan.extract(
            file("-rf.zip"), format: .zip, workingDirectory: "/d", into: .thisFolder)
        #expect(plan.words.contains(.operand("./-rf.zip")))
    }

    @Test func thelocalInvocationIsArgvWithNoQuotingAndNoShell() throws {
        let plan = try ArchivePlan.compress(
            .zip, selection: [file("a'b")],
            workingDirectory: "/d", archiveName: "out.zip")
        let invocation = try plan.localInvocation(resolvingToolWith: { "/usr/bin/" + $0 })
        #expect(invocation.executable == URL(fileURLWithPath: "/usr/bin/zip"))
        #expect(invocation.arguments == ["-r", "-@", "out.zip"])
        #expect(invocation.currentDirectory == URL(fileURLWithPath: "/d"))
        #expect(invocation.stdin == Data("a'b\n".utf8))
    }
}
