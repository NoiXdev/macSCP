import Foundation
import Testing
@testable import macSCPCore

/// A directory listing arrives as raw lines. These pin the two readers
/// (`MLSD` facts, and the Unix and DOS `LIST` shapes) as pure functions over
/// bytes -- no socket, no server. Every fixture is a literal in the test.
///
/// Two failure modes are kept apart on purpose, and the suite holds them
/// apart: a NAME that is not valid UTF-8 is read as Latin-1 and never fails
/// the listing, while a LINE in no known dialect fails the whole directory.
@Suite("FTP listing parsing")
struct FTPListParserTests {
    /// UTC epoch seconds, from `date -u`, not from the parser under test.
    private let jan5_2024_1340: TimeInterval = 1_704_462_000

    private func bytes(_ lines: [String]) -> [Data] { lines.map { Data($0.utf8) } }

    // MARK: MLSD

    @Test func mlsdReadsTypeSizeAndModifyFacts() throws {
        let items = try FTPListParser.mlsd(
            bytes([
                "type=file;size=1234;modify=20240105134000; report.pdf",
                "type=dir;modify=20240105134000; docs",
            ]), at: "/home")
        #expect(items.count == 2)
        let file = try #require(items.first)
        #expect(file.name == "report.pdf")
        #expect(file.path == "/home/report.pdf")
        #expect(file.kind == .file)
        #expect(file.size == 1234)
        #expect(file.modifiedAt == Date(timeIntervalSince1970: jan5_2024_1340))
        let dir = try #require(items.last)
        #expect(dir.name == "docs")
        #expect(dir.kind == .directory)
        #expect(dir.size == nil)
    }

    @Test func mlsdReportsASymlinkFromItsUnixFact() throws {
        let items = try FTPListParser.mlsd(
            bytes([
                "type=OS.unix=symlink;size=11; current",
                "type=OS.unix=slink:/srv/data;size=8; other",
            ]), at: "/")
        #expect(items.map(\.kind) == [.symlink, .symlink])
        #expect(items.map(\.path) == ["/current", "/other"])
    }

    @Test func mlsdSkipsTheDotAndDotDotEntries() throws {
        let items = try FTPListParser.mlsd(
            bytes([
                "type=cdir;modify=20240105134000; /home",
                "type=pdir;modify=20240105134000; /",
                "type=dir; .",
                "type=dir; ..",
                "type=file;size=1; kept.txt",
            ]), at: "/home")
        // The positive half: the scan found the real entry, so an empty
        // result for the others is a skip and not a parser that read nothing.
        #expect(items.map(\.name) == ["kept.txt"])
    }

    @Test func mlsdTakesTheNameAfterTheFirstSpaceWithItsSpacesAndSemicolons() throws {
        let items = try FTPListParser.mlsd(
            bytes(["type=file;size=2; my notes; draft 2.txt"]), at: "/")
        #expect(items.map(\.name) == ["my notes; draft 2.txt"])
    }

    @Test func mlsdReadsUnixModeOwnerAndGroupFacts() throws {
        let items = try FTPListParser.mlsd(
            bytes(["type=file;size=2;UNIX.mode=0644;UNIX.owner=alice;UNIX.group=staff; a"]),
            at: "/")
        let item = try #require(items.first)
        #expect(item.permissions == 0o644)
        #expect(item.owner == "alice")
        #expect(item.group == "staff")
    }

    @Test func mlsdRefusesALineWithoutATypeFactByItsIndex() throws {
        let fine = bytes(["type=file;size=1; fine"])
        // The positive half: the good line alone parses.
        #expect(try FTPListParser.mlsd(fine, at: "/").count == 1)
        let lines = fine + bytes(["size=1; no-type"])
        #expect(throws: FTPListRefusal.unreadableLine(index: 1)) {
            try FTPListParser.mlsd(lines, at: "/")
        }
    }

    // MARK: Unix LIST

    @Test func unixListReadsAFileWithAYearInPlaceOfATime() throws {
        let items = try FTPListParser.list(
            bytes(["-rw-r--r--   1 alice    staff        2048 Jan  5  2024 report.pdf"]),
            at: "/home")
        let item = try #require(items.first)
        #expect(item.name == "report.pdf")
        #expect(item.path == "/home/report.pdf")
        #expect(item.kind == .file)
        #expect(item.size == 2048)
        #expect(item.permissions == 0o644)
        #expect(item.owner == "alice")
        #expect(item.group == "staff")
        // A date with no time of day reads as midnight UTC.
        #expect(item.modifiedAt == Date(timeIntervalSince1970: 1_704_412_800))
    }

    @Test func unixListReadsARecentFileWithATimeAndNoYear() throws {
        let now = Date(timeIntervalSince1970: 1_773_144_000)  // 2026-03-10 12:00 UTC
        let items = try FTPListParser.list(
            bytes([
                "-rw-r--r--   1 alice staff 10 Jan  5 13:40 this-year.txt",
                "-rw-r--r--   1 alice staff 10 Nov 20 13:40 last-year.txt",
            ]), at: "/", now: now)
        // "Jan 5" is in the past of this year; "Nov 20" would be eight months
        // ahead of `now` this year, so it can only be last year's.
        #expect(items[0].modifiedAt == Date(timeIntervalSince1970: 1_767_620_400))
        #expect(items[1].modifiedAt == Date(timeIntervalSince1970: 1_763_646_000))
    }

    @Test func unixListReadsANameContainingSpaces() throws {
        let items = try FTPListParser.list(
            bytes(["-rw-r--r--   1 alice staff 10 Jan  5  2024 my  holiday photo.jpg"]),
            at: "/")
        #expect(items.map(\.name) == ["my  holiday photo.jpg"])
    }

    @Test func unixListReadsADirectoryAndASymlinkAndDropsTheLinkTarget() throws {
        let items = try FTPListParser.list(
            bytes([
                "drwxr-xr-x   2 alice staff 4096 Jan  5  2024 docs",
                "lrwxrwxrwx   1 alice staff   11 Jan  5  2024 current -> releases/v2",
            ]), at: "/srv")
        #expect(items.map(\.kind) == [.directory, .symlink])
        #expect(items.map(\.name) == ["docs", "current"])
        #expect(items[0].permissions == 0o755)
    }

    @Test func unixListSkipsTheTotalLineAndTheDotEntries() throws {
        let items = try FTPListParser.list(
            bytes([
                "total 12",
                "drwxr-xr-x   2 alice staff 4096 Jan  5  2024 .",
                "drwxr-xr-x   3 alice staff 4096 Jan  5  2024 ..",
                "-rw-r--r--   1 alice staff   10 Jan  5  2024 kept.txt",
            ]), at: "/")
        #expect(items.map(\.name) == ["kept.txt"])
    }

    @Test func unixListReadsSetuidAndStickyBits() throws {
        let items = try FTPListParser.list(
            bytes([
                "-rwsr-xr-x   1 root root 10 Jan  5  2024 su",
                "drwxrwxrwt   2 root root 10 Jan  5  2024 tmp",
                "-rwSr--r--   1 root root 10 Jan  5  2024 odd",
            ]), at: "/")
        #expect(items.map(\.permissions) == [0o4755, 0o1777, 0o4644])
    }

    // MARK: DOS LIST

    @Test func dosListReadsADirectoryMarkedWithDIR() throws {
        let items = try FTPListParser.list(
            bytes(["01-05-24  01:40PM       <DIR>          archive"]), at: "/")
        let item = try #require(items.first)
        #expect(item.name == "archive")
        #expect(item.kind == .directory)
        #expect(item.size == nil)
        #expect(item.modifiedAt == Date(timeIntervalSince1970: jan5_2024_1340))
    }

    @Test func dosListReadsAFileWithASizeAndTheTwelveHourClockEdges() throws {
        let items = try FTPListParser.list(
            bytes([
                "01-05-2024  11:05PM              4096 late night.log",
                "01-05-24  12:05AM                 7 just after midnight.txt",
            ]), at: "/")
        #expect(items.map(\.name) == ["late night.log", "just after midnight.txt"])
        #expect(items.map(\.size) == [4096, 7])
        #expect(items[0].modifiedAt == Date(timeIntervalSince1970: 1_704_495_900))
        #expect(items[1].modifiedAt == Date(timeIntervalSince1970: 1_704_413_100))
    }

    // MARK: The two failure modes

    @Test func aLineInNoKnownDialectIsRefusedByItsIndex() throws {
        let good = "-rw-r--r--   1 alice staff 10 Jan  5  2024 ok.txt"
        // The positive half: without the bad line the same listing parses.
        #expect(try FTPListParser.list(bytes([good, good]), at: "/").count == 2)
        #expect(throws: FTPListRefusal.unreadableLine(index: 1)) {
            try FTPListParser.list(bytes([good, "this is not a listing", good]), at: "/")
        }
    }

    @Test func aNameThatCouldEscapeItsDirectoryIsRefusedNotJoined() throws {
        #expect(throws: FTPListRefusal.unreadableLine(index: 0)) {
            try FTPListParser.mlsd(bytes(["type=file;size=1; ../../etc/passwd"]), at: "/home")
        }
        #expect(throws: FTPListRefusal.unreadableLine(index: 0)) {
            try FTPListParser.list(
                bytes(["-rw-r--r-- 1 a b 1 Jan  5  2024 x/y"]), at: "/home")
        }
    }

    @Test func aNameThatIsNotValidUTF8SurvivesAsItsLatin1Reading() throws {
        let latin1Name = Data([0x63, 0x61, 0x66, 0xE9])  // "caf" + 0xE9, not valid UTF-8
        #expect(String(data: latin1Name, encoding: .utf8) == nil)
        let mlsd = Data("type=file;size=1; ".utf8) + latin1Name
        let list = Data("-rw-r--r-- 1 a b 1 Jan  5  2024 ".utf8) + latin1Name
        #expect(try FTPListParser.mlsd([mlsd], at: "/").map(\.name) == ["caf\u{E9}"])
        #expect(try FTPListParser.list([list], at: "/").map(\.name) == ["caf\u{E9}"])
        // The positive control: the same word sent as UTF-8 stays UTF-8 and is
        // not re-read as Latin-1 (which would give "cafÃ©").
        let utf8 = Data("type=file;size=1; caf\u{E9}".utf8)
        #expect(try FTPListParser.mlsd([utf8], at: "/").map(\.name) == ["caf\u{E9}"])
    }

    @Test func oneUndecodableNameDoesNotVoidTheOtherEntries() throws {
        let broken = Data("type=file;size=1; ".utf8) + Data([0xFF, 0xFE, 0x41])
        let lines = [
            Data("type=file;size=1; before".utf8), broken, Data("type=dir; after".utf8),
        ]
        let items = try FTPListParser.mlsd(lines, at: "/")
        #expect(items.count == 3)
        #expect(items[0].name == "before")
        #expect(items[1].name == "\u{FF}\u{FE}A")
        #expect(items[2].name == "after")
    }
}
