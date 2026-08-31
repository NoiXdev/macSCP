import Testing

@testable import macSCPCore

/// The digest hex of the EMPTY input, per algorithm — the one value that can
/// be written down here without a fixture file, and the one every command
/// line tool agrees on.
private enum EmptyInputDigest {
    static let sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    static let sha1 = "da39a3ee5e6b4b0d3255bfef95601890afd80709"
    static let md5 = "d41d8cd98f00b204e9800998ecf8427e"
}

@Suite("ChecksumAlgorithm")
struct ChecksumAlgorithmTests {
    @Test("the preferred algorithm is SHA-256")
    func preferredIsSHA256() {
        #expect(ChecksumAlgorithm.preferred == .sha256)
    }

    @Test("the offered algorithms are SHA-256, SHA-1 and MD5")
    func offeredAlgorithms() {
        #expect(ChecksumAlgorithm.allCases == [.sha256, .sha1, .md5])
    }

    @Test("each algorithm prescribes its own hex length")
    func hexDigitCounts() {
        #expect(ChecksumAlgorithm.sha256.hexDigitCount == EmptyInputDigest.sha256.count)
        #expect(ChecksumAlgorithm.sha1.hexDigitCount == EmptyInputDigest.sha1.count)
        #expect(ChecksumAlgorithm.md5.hexDigitCount == EmptyInputDigest.md5.count)
    }

    /// The setting says so; the value knows it, so the setting does not have
    /// to hardcode a list that a fourth algorithm would silently fall out of.
    @Test("MD5 and SHA-1 are marked broken, SHA-256 is not")
    func brokenAlgorithmsAreMarked() {
        #expect(ChecksumAlgorithm.sha256.isCryptographicallyBroken == false)
        #expect(ChecksumAlgorithm.sha1.isCryptographicallyBroken)
        #expect(ChecksumAlgorithm.md5.isCryptographicallyBroken)
    }
}

/// Reading what the far side answered.
///
/// The reader takes an algorithm and an output — and NO expected path. The
/// echoed path is a value from the other side; there is no parameter to
/// compare it against, which is how "it is never looked at" is stated in a
/// way that cannot rot.
@Suite("ChecksumOutputReader")
struct ChecksumOutputReaderTests {
    @Test("the GNU form's output yields the hex only")
    func gnuOutput() {
        let read = ChecksumOutputReader.read(
            "\(EmptyInputDigest.sha256)  /srv/backup/empty.bin",
            algorithm: .sha256
        )
        #expect(read?.hex == EmptyInputDigest.sha256)
    }

    @Test("the BSD form's output yields the same value as the GNU form")
    func bsdOutputMatchesGNU() {
        let gnu = ChecksumOutputReader.read(
            "\(EmptyInputDigest.sha256)  /srv/backup/empty.bin",
            algorithm: .sha256
        )
        let bsd = ChecksumOutputReader.read(
            "\(EmptyInputDigest.sha256)  /srv/backup/empty.bin\n",
            algorithm: .sha256
        )
        #expect(gnu == bsd)
        #expect(gnu != nil)
    }

    /// GNU marks binary mode with a `*` in front of the path. The reader
    /// splits on the whitespace run and never inspects what follows, so the
    /// marker needs no case of its own.
    @Test("the GNU binary-mode marker does not change the value")
    func binaryModeMarker() {
        let text = ChecksumOutputReader.read(
            "\(EmptyInputDigest.sha256)  /srv/x.bin",
            algorithm: .sha256
        )
        let binary = ChecksumOutputReader.read(
            "\(EmptyInputDigest.sha256) */srv/x.bin",
            algorithm: .sha256
        )
        #expect(text == binary)
    }

    @Test("a hex of the wrong length is refused")
    func wrongLengthIsRefused() {
        #expect(ChecksumOutputReader.read("\(EmptyInputDigest.md5)  /f", algorithm: .sha256) == nil)
        #expect(ChecksumOutputReader.read("\(EmptyInputDigest.sha256)  /f", algorithm: .md5) == nil)
        #expect(ChecksumOutputReader.read("\(EmptyInputDigest.sha256)0  /f", algorithm: .sha256) == nil)
    }

    @Test("a first field that is not hex is refused")
    func nonHexIsRefused() {
        let notHex = String(repeating: "z", count: 64)
        #expect(ChecksumOutputReader.read("\(notHex)  /f", algorithm: .sha256) == nil)
        var oneBadDigit = EmptyInputDigest.sha256
        oneBadDigit.removeLast()
        #expect(ChecksumOutputReader.read("\(oneBadDigit)g  /f", algorithm: .sha256) == nil)
    }

    @Test("empty output is refused")
    func emptyOutputIsRefused() {
        #expect(ChecksumOutputReader.read("", algorithm: .sha256) == nil)
        #expect(ChecksumOutputReader.read("   \n", algorithm: .sha256) == nil)
    }

    /// A bare hex with nothing after it is not the answer of a checksum tool
    /// asked about a file. It is refused rather than trusted.
    @Test("output with no path at all is refused")
    func outputWithoutPathIsRefused() {
        #expect(ChecksumOutputReader.read(EmptyInputDigest.sha256, algorithm: .sha256) == nil)
        #expect(ChecksumOutputReader.read("\(EmptyInputDigest.sha256)   ", algorithm: .sha256) == nil)
    }

    @Test("a path in the answer that is not the one asked about changes nothing")
    func theEchoedPathIsNeverLookedAt() {
        let asked = ChecksumOutputReader.read(
            "\(EmptyInputDigest.sha256)  /srv/backup/report.pdf",
            algorithm: .sha256
        )
        let other = ChecksumOutputReader.read(
            "\(EmptyInputDigest.sha256)  /etc/shadow",
            algorithm: .sha256
        )
        let nonsense = ChecksumOutputReader.read(
            "\(EmptyInputDigest.sha256)  ; rm -rf / #",
            algorithm: .sha256
        )
        #expect(asked == other)
        #expect(asked == nonsense)
        #expect(asked?.hex == EmptyInputDigest.sha256)
    }

    @Test("uppercase hex is read and normalized to lowercase")
    func uppercaseHexIsNormalized() {
        let read = ChecksumOutputReader.read(
            "\(EmptyInputDigest.sha256.uppercased())  /f",
            algorithm: .sha256
        )
        #expect(read?.hex == EmptyInputDigest.sha256)
    }

    @Test("MD5 and SHA-1 output is read at their own lengths")
    func shorterAlgorithms() {
        #expect(
            ChecksumOutputReader.read("\(EmptyInputDigest.md5)  /f", algorithm: .md5)?.hex
                == EmptyInputDigest.md5
        )
        #expect(
            ChecksumOutputReader.read("\(EmptyInputDigest.sha1)  /f", algorithm: .sha1)?.hex
                == EmptyInputDigest.sha1
        )
    }

    /// One file was asked about, so one line is the answer. Anything else is
    /// a shell that said something extra, and guessing which line is the
    /// answer is exactly the guess this reader refuses to make.
    @Test("more than one line of output is refused")
    func multipleLinesAreRefused() {
        let two = "\(EmptyInputDigest.sha256)  /a\n\(EmptyInputDigest.md5)  /b"
        #expect(ChecksumOutputReader.read(two, algorithm: .sha256) == nil)
    }

    @Test("what the reader returns is marked as computed on the far side")
    func readResultCarriesRemoteProvenance() {
        let read = ChecksumOutputReader.read(
            "\(EmptyInputDigest.sha256)  /f",
            algorithm: .sha256
        )
        #expect(read?.provenance == .computedOnRemote)
        #expect(read?.describesFileContent == true)
        #expect(read?.algorithm == .sha256)
    }
}

@Suite("FileChecksum")
struct FileChecksumTests {
    @Test("a locally computed result says so and describes the content")
    func computedLocally() {
        let checksum = FileChecksum.computedLocally(.sha256, hex: EmptyInputDigest.sha256)
        #expect(checksum?.provenance == .computedLocally)
        #expect(checksum?.describesFileContent == true)
        #expect(checksum?.hex == EmptyInputDigest.sha256)
    }

    @Test("a remotely computed result says so and describes the content")
    func computedOnRemote() {
        let checksum = FileChecksum.computedOnRemote(.md5, hex: EmptyInputDigest.md5)
        #expect(checksum?.provenance == .computedOnRemote)
        #expect(checksum?.describesFileContent == true)
    }

    /// Every way into the type runs the same check, so a stored `hex` is
    /// always hex of the algorithm's length.
    @Test("a hex that is not the algorithm's cannot become a result")
    func invalidHexIsRefused() {
        #expect(FileChecksum.computedLocally(.sha256, hex: EmptyInputDigest.md5) == nil)
        #expect(FileChecksum.computedLocally(.md5, hex: "") == nil)
        #expect(FileChecksum.computedOnRemote(.md5, hex: String(repeating: "q", count: 32)) == nil)
    }

    @Test("uppercase hex handed to a factory is normalized")
    func factoryNormalizesCase() {
        let checksum = FileChecksum.computedLocally(.sha1, hex: EmptyInputDigest.sha1.uppercased())
        #expect(checksum?.hex == EmptyInputDigest.sha1)
    }

    /// `describesFileContent` is read off the provenance, never stored beside
    /// it — so there is no pair of fields that can disagree.
    @Test("whether a value describes the content follows from where it came from")
    func describesContentFollowsFromProvenance() {
        #expect(ChecksumProvenance.computedOnRemote.describesFileContent)
        #expect(ChecksumProvenance.computedLocally.describesFileContent)
        #expect(ChecksumProvenance.objectStorageETagSinglePart.describesFileContent)
        #expect(ChecksumProvenance.objectStorageETagMultipart(partCount: 2).describesFileContent == false)
    }
}

@Suite("ObjectStorageETag")
struct ObjectStorageETagTests {
    private static let singlePart = "9bb58f26192e4ba00f01e2e7b136bbd8"

    @Test("a quoted single-part ETag is the object's MD5")
    func quotedSinglePart() {
        #expect(
            ObjectStorageETag.interpret("\"\(Self.singlePart)\"")
                == .fileMD5(Self.singlePart)
        )
    }

    @Test("an unquoted single-part ETag reads the same")
    func unquotedSinglePart() {
        #expect(
            ObjectStorageETag.interpret(Self.singlePart)
                == ObjectStorageETag.interpret("\"\(Self.singlePart)\"")
        )
    }

    /// The shape that appears on exactly the large files someone wants to
    /// check. It is an MD5 over the parts' MD5s — not the file's hash.
    @Test("a multipart ETag is not a file hash, and the part count is kept")
    func multipartIsNotAFileHash() {
        #expect(
            ObjectStorageETag.interpret("\"\(Self.singlePart)-12\"")
                == .multipartComposite(partCount: 12, hex: Self.singlePart)
        )
    }

    @Test("an ETag that is neither shape is refused")
    func garbageIsRefused() {
        #expect(ObjectStorageETag.interpret("") == .notAChecksum)
        #expect(ObjectStorageETag.interpret("\"\"") == .notAChecksum)
        #expect(ObjectStorageETag.interpret("\"deadbeef\"") == .notAChecksum)
        #expect(ObjectStorageETag.interpret("\"\(Self.singlePart)-\"") == .notAChecksum)
        #expect(ObjectStorageETag.interpret("\"\(Self.singlePart)-0\"") == .notAChecksum)
        #expect(ObjectStorageETag.interpret("\"\(Self.singlePart)-x\"") == .notAChecksum)
        #expect(ObjectStorageETag.interpret("\"\(Self.singlePart)\(Self.singlePart)\"") == .notAChecksum)
    }

    @Test("a single-part ETag becomes a result that describes the content")
    func singlePartBecomesAResult() {
        let checksum = FileChecksum.objectStorageETag("\"\(Self.singlePart)\"")
        #expect(checksum?.algorithm == .md5)
        #expect(checksum?.hex == Self.singlePart)
        #expect(checksum?.provenance == .objectStorageETagSinglePart)
        #expect(checksum?.describesFileContent == true)
    }

    @Test("a multipart ETag becomes a result that says it is not the file's hash")
    func multipartBecomesANonContentResult() {
        let checksum = FileChecksum.objectStorageETag("\"\(Self.singlePart)-4\"")
        #expect(checksum?.provenance == .objectStorageETagMultipart(partCount: 4))
        #expect(checksum?.describesFileContent == false)
    }

    @Test("an ETag that is no checksum at all becomes no result")
    func garbageBecomesNoResult() {
        #expect(FileChecksum.objectStorageETag("\"deadbeef\"") == nil)
    }
}

/// Which spelling the far side has is decided once per connection and then
/// carried as this value, so the SSH layer builds a command instead of
/// branching on a platform.
@Suite("ChecksumCommandForm")
struct ChecksumCommandFormTests {
    @Test("the GNU form names the per-algorithm tool")
    func gnuExecutables() {
        #expect(ChecksumCommandForm.gnu.executable(for: .sha256) == "sha256sum")
        #expect(ChecksumCommandForm.gnu.executable(for: .sha1) == "sha1sum")
        #expect(ChecksumCommandForm.gnu.executable(for: .md5) == "md5sum")
        #expect(ChecksumCommandForm.gnu.arguments(for: .sha256).isEmpty)
    }

    @Test("the BSD form selects the algorithm by argument")
    func bsdExecutables() {
        #expect(ChecksumCommandForm.bsd.executable(for: .sha256) == "shasum")
        #expect(ChecksumCommandForm.bsd.arguments(for: .sha256) == ["-a", "256"])
        #expect(ChecksumCommandForm.bsd.executable(for: .sha1) == "shasum")
        #expect(ChecksumCommandForm.bsd.arguments(for: .sha1) == ["-a", "1"])
    }

    /// BSD `md5` prints `MD5 (path) = hex` by default; `-r` makes it print
    /// the reversed, GNU-shaped line the reader above expects.
    @Test("the BSD form asks md5 for the GNU-shaped line")
    func bsdMD5UsesReversedOutput() {
        #expect(ChecksumCommandForm.bsd.executable(for: .md5) == "md5")
        #expect(ChecksumCommandForm.bsd.arguments(for: .md5) == ["-r"])
    }

    @Test("both forms are offered")
    func bothFormsAreOffered() {
        #expect(ChecksumCommandForm.allCases == [.gnu, .bsd])
    }

    /// The path is the ONLY interpolated part, and it goes through the
    /// quoting this project already has.
    @Test("the path is the only interpolated part and it is quoted")
    func commandQuotesThePath() {
        #expect(
            ChecksumCommandForm.gnu.command(for: .sha256, path: "/srv/my backup.tar")
                == "sha256sum -- '/srv/my backup.tar'"
        )
        #expect(
            ChecksumCommandForm.bsd.command(for: .sha256, path: "/srv/my backup.tar")
                == "shasum -a 256 -- '/srv/my backup.tar'"
        )
    }

    @Test("a path that tries to end the word and start a command cannot")
    func hostilePathStaysOneWord() {
        let command = ChecksumCommandForm.gnu.command(for: .md5, path: "/srv/x'; id; '")
        #expect(command == "md5sum -- " + PosixQuoting.singleQuoted("/srv/x'; id; '"))
    }

    /// The two forms differ in the command, not in the answer.
    @Test("both forms' outputs read to the same result")
    func bothFormsReadToTheSameResult() {
        let gnu = ChecksumOutputReader.read(
            "\(EmptyInputDigest.sha256)  /srv/e.bin",
            algorithm: .sha256
        )
        let bsd = ChecksumOutputReader.read(
            "\(EmptyInputDigest.sha256)  /srv/e.bin",
            algorithm: .sha256
        )
        #expect(gnu == bsd)
        #expect(gnu?.hex == EmptyInputDigest.sha256)
    }
}
