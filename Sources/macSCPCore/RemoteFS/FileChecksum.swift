import Foundation

/// The digest procedures this project offers for a file.
///
/// SHA-256 is the preferred one. MD5 and SHA-1 exist because the most common
/// real occasion is comparing against a figure someone else published, and
/// that figure is often an MD5 — not because they are equal choices.
public enum ChecksumAlgorithm: String, Sendable, Equatable, CaseIterable {
    case sha256
    case sha1
    case md5

    /// The one picked when nobody picked.
    public static let preferred: ChecksumAlgorithm = .sha256

    /// How many hex digits a digest of this procedure has. This is the whole
    /// length rule the output reader enforces; there is no second copy of it.
    public var hexDigitCount: Int {
        switch self {
        case .sha256: 64
        case .sha1: 40
        case .md5: 32
        }
    }

    /// The procedure's own name, as its standard spells it and as a
    /// published figure spells it beside a download link.
    ///
    /// Deliberately NOT localized, and not a catalogue key: this is a name,
    /// like `KB/s` in the transfer settings, and the whole point of showing
    /// it is that it matches the label somebody is comparing against.
    /// Translating it would make that comparison harder, not easier.
    public var displayName: String {
        switch self {
        case .sha256: "SHA-256"
        case .sha1: "SHA-1"
        case .md5: "MD5"
        }
    }

    /// Whether collisions are producible for this procedure. A settings
    /// surface reads this instead of carrying its own list of which
    /// algorithms need the warning — the difference to say is that they still
    /// serve to compare against a published figure, but not to prove that two
    /// files are the same.
    public var isCryptographicallyBroken: Bool {
        switch self {
        case .sha256: false
        case .sha1, .md5: true
        }
    }

    /// `candidate` lowercased, if it is ASCII hex of exactly this
    /// procedure's length; `nil` otherwise.
    ///
    /// `isASCII` is checked alongside `isHexDigit` because `isHexDigit` is
    /// true for fullwidth and other non-ASCII digit forms as well, and a
    /// digest field is ASCII or it is not a digest field.
    public func normalizedHex(_ candidate: String) -> String? {
        guard candidate.count == hexDigitCount else { return nil }
        var lowered = ""
        lowered.reserveCapacity(hexDigitCount)
        for character in candidate {
            guard character.isASCII, character.isHexDigit else { return nil }
            lowered.append(contentsOf: character.lowercased())
        }
        return lowered
    }
}

/// Where a checksum came from, and — derived from that, never stored beside
/// it — whether it describes the file's bytes.
///
/// The object-storage cases are why this exists. An ETag is the object's MD5
/// only for an upload that arrived in one part; for a multipart upload it is
/// an MD5 over the parts' MD5s, and that shape appears on exactly the large
/// files someone wants to check. A display that can omit this eventually
/// will, so it is not a footnote next to the value — it is part of it.
public enum ChecksumProvenance: Sendable, Equatable {
    /// Computed by the far side, over the file's bytes.
    case computedOnRemote
    /// Computed here, over a local file's bytes.
    case computedLocally
    /// An object store's ETag for an upload that arrived in one part: the
    /// MD5 of the object's bytes.
    case objectStorageETagSinglePart
    /// An object store's ETag for a multipart upload: an MD5 over the parts'
    /// MD5s. Not the file's hash, whatever it looks like.
    case objectStorageETagMultipart(partCount: Int)

    public var describesFileContent: Bool {
        switch self {
        case .computedOnRemote, .computedLocally, .objectStorageETagSinglePart: true
        case .objectStorageETagMultipart: false
        }
    }
}

/// A checksum of one file, inseparable from where it came from.
///
/// The initializer is private and there is no memberwise one: the only ways
/// in are the factories below, and each of them NAMES a provenance. A caller
/// therefore cannot spell a construction that leaves the provenance out —
/// not because a test forbids it, but because there is no such expression.
/// Every factory runs the same hex check, so a stored `hex` is always
/// lowercase hex of `algorithm.hexDigitCount` digits.
public struct FileChecksum: Sendable, Equatable {
    public let algorithm: ChecksumAlgorithm
    public let hex: String
    public let provenance: ChecksumProvenance

    private init(algorithm: ChecksumAlgorithm, hex: String, provenance: ChecksumProvenance) {
        self.algorithm = algorithm
        self.hex = hex
        self.provenance = provenance
    }

    public var describesFileContent: Bool { provenance.describesFileContent }

    /// A digest the far side computed and reported.
    public static func computedOnRemote(_ algorithm: ChecksumAlgorithm, hex: String) -> FileChecksum? {
        guard let normalized = algorithm.normalizedHex(hex) else { return nil }
        return FileChecksum(algorithm: algorithm, hex: normalized, provenance: .computedOnRemote)
    }

    /// A digest computed here over a local file.
    public static func computedLocally(_ algorithm: ChecksumAlgorithm, hex: String) -> FileChecksum? {
        guard let normalized = algorithm.normalizedHex(hex) else { return nil }
        return FileChecksum(algorithm: algorithm, hex: normalized, provenance: .computedLocally)
    }

    /// An object store's ETag, read for what it actually is. A multipart
    /// ETag still becomes a value — one that says it does not describe the
    /// file's content — because refusing to show it and showing it as a file
    /// hash are both worse than showing it for what it is.
    public static func objectStorageETag(_ raw: String) -> FileChecksum? {
        switch ObjectStorageETag.interpret(raw) {
        case .fileMD5(let hex):
            return FileChecksum(algorithm: .md5, hex: hex, provenance: .objectStorageETagSinglePart)
        case .multipartComposite(let partCount, let hex):
            return FileChecksum(
                algorithm: .md5,
                hex: hex,
                provenance: .objectStorageETagMultipart(partCount: partCount)
            )
        case .notAChecksum:
            return nil
        }
    }
}

/// What an object store's ETag turned out to be.
public enum ETagInterpretation: Sendable, Equatable {
    /// The MD5 of the object's bytes, lowercased.
    case fileMD5(String)
    /// An MD5 over the MD5s of `partCount` parts, plus that composite's own
    /// hex — a value that can be shown, but never as the file's hash.
    case multipartComposite(partCount: Int, hex: String)
    /// Neither shape. Some stores put arbitrary opaque text here.
    case notAChecksum
}

public enum ObjectStorageETag {
    /// Decides whether `raw` is a file hash.
    ///
    /// S3 delivers the ETag wrapped in double quotes, and a multipart upload
    /// appends `-N` for the number of parts. Both are handled here so no
    /// backend has to know the shape.
    public static func interpret(_ raw: String) -> ETagInterpretation {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }

        if let dash = value.firstIndex(of: "-") {
            let digest = String(value[value.startIndex..<dash])
            let counted = String(value[value.index(after: dash)...])
            guard let hex = ChecksumAlgorithm.md5.normalizedHex(digest),
                !counted.isEmpty,
                counted.allSatisfy({ $0.isASCII && $0.isNumber }),
                let partCount = Int(counted),
                partCount > 0
            else { return .notAChecksum }
            return .multipartComposite(partCount: partCount, hex: hex)
        }

        guard let hex = ChecksumAlgorithm.md5.normalizedHex(value) else { return .notAChecksum }
        return .fileMD5(hex)
    }
}

/// Reading what a checksum tool on the far side answered.
///
/// A checksum tool answers `<hex>  <path>`. Only the first field is read,
/// and only if it is hex of the length the procedure prescribes.
///
/// `read` takes an algorithm and an output — and no expected path. The
/// echoed path comes from the other side, so it is input: it is neither
/// compared nor shown, and the absence of a parameter to compare it against
/// is how that is stated in a form that cannot drift. Which file a value
/// belongs to is known by the caller that asked.
///
/// A pure function, so it is decidable without any connection.
public enum ChecksumOutputReader {
    public static func read(_ output: String, algorithm: ChecksumAlgorithm) -> FileChecksum? {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .filter { !$0.allSatisfy(\.isWhitespace) }
        // One file was asked about, so one line is the answer. Picking a line
        // out of several would be guessing which one the shell meant.
        guard lines.count == 1, let line = lines.first else { return nil }

        let fields = line.split(whereSeparator: \.isWhitespace)
        // A bare digest with nothing after it is not a checksum tool's answer
        // about a file. Everything past the first whitespace run is the
        // echoed path (GNU's binary-mode `*` marker included) and is only
        // required to be there, never inspected.
        guard fields.count >= 2 else { return nil }

        guard let hex = algorithm.normalizedHex(String(fields[0])) else { return nil }
        return FileChecksum.computedOnRemote(algorithm, hex: hex)
    }
}

/// Which spelling of the checksum tools the far side has.
///
/// `sha256sum` is GNU; BSD and macOS spell it `shasum -a 256`. This is asked
/// once per connection and the answer is carried as this value, so the SSH
/// layer builds a command from a value instead of branching on a platform —
/// and no compound `&&`/`||` line tries to cover both cases at once.
///
/// Note what this does NOT offer: a way to pass a command. The only
/// interpolated part of the produced line is the path, and it goes through
/// `PosixQuoting`.
public enum ChecksumCommandForm: String, Sendable, Equatable, CaseIterable {
    case gnu
    case bsd

    /// The tool's name — also the thing to probe for when deciding which
    /// form a connection has, so the names live in one place.
    public func executable(for algorithm: ChecksumAlgorithm) -> String {
        switch (self, algorithm) {
        case (.gnu, .sha256): "sha256sum"
        case (.gnu, .sha1): "sha1sum"
        case (.gnu, .md5): "md5sum"
        case (.bsd, .sha256), (.bsd, .sha1): "shasum"
        case (.bsd, .md5): "md5"
        }
    }

    /// The arguments before the path. BSD `md5` prints `MD5 (path) = hex`
    /// by default; `-r` makes it print the reversed, GNU-shaped line that
    /// `ChecksumOutputReader` reads.
    public func arguments(for algorithm: ChecksumAlgorithm) -> [String] {
        switch (self, algorithm) {
        case (.gnu, _): []
        case (.bsd, .sha256): ["-a", "256"]
        case (.bsd, .sha1): ["-a", "1"]
        case (.bsd, .md5): ["-r"]
        }
    }

    /// The full command line. `--` ends the options so a path beginning with
    /// a dash stays a path, and the path itself is one shell word.
    ///
    /// Measured on 2026-08-31, because the `--` for BSD `md5` was carried out
    /// of Task 1 unverified: `/sbin/md5 -r -- ./-p.txt` on macOS 26.6.2
    /// answered a GNU-shaped line, and `/sbin/md5 -r -p.txt` — the same call
    /// without the terminator — answered `invalid option -- .` and exited 1.
    /// So the terminator is both accepted and load-bearing for that tool, and
    /// nothing here needs a per-tool exception.
    public func command(for algorithm: ChecksumAlgorithm, path: String) -> String {
        let head = ([executable(for: algorithm)] + arguments(for: algorithm) + ["--"])
            .joined(separator: " ")
        return head + " " + PosixQuoting.singleQuoted(path)
    }

    /// The line that asks the far side whether this form is there at all,
    /// without running any checksum tool.
    ///
    /// `command -v` is the POSIX shell's own answer to "do you have this":
    /// exit 0 and the resolved path if the name is there, non-zero if it is
    /// not. It executes nothing — which also rules out the accident of
    /// starting a checksum tool with no operand, where every one of them
    /// reads standard input and never returns.
    ///
    /// The tool it names is this form's executable for
    /// `ChecksumAlgorithm.preferred`, read from `executable(for:)` rather
    /// than spelled again: a form is a claim about a whole family of tools
    /// on one far side, and the preferred algorithm's is the one that stands
    /// for the family.
    public func presenceProbeLine() -> ChecksumCommandLine {
        ChecksumCommandLine(
            text: "command -v " + PosixQuoting.singleQuoted(executable(for: .preferred)))
    }

    /// The line that asks for one file's digest.
    public func commandLine(for algorithm: ChecksumAlgorithm, path: String) -> ChecksumCommandLine {
        ChecksumCommandLine(text: command(for: algorithm, path: path))
    }
}

/// One command line this module is willing to have run on a far side.
///
/// The initializer is `fileprivate` and there is no memberwise one, so the
/// only expressions in the whole package that produce a value of this type
/// are `ChecksumCommandForm.presenceProbeLine()` and
/// `ChecksumCommandForm.commandLine(for:path:)` above — two lines whose only
/// interpolated part is a path, and it goes through `PosixQuoting`.
///
/// That is why the type exists at all. `ChecksumCommandChannel`, the seam
/// that actually runs something on a connection, takes THIS and not a
/// `String`: "run this arbitrary text over there" is not an expression the
/// package can form, in a test double no less than in production. A
/// convention would have said the same thing and bought nothing — the same
/// argument `FileChecksum` makes for its private init and
/// `BoundedSFTPSession` makes for the unbounded close.
public struct ChecksumCommandLine: Sendable, Equatable {
    /// The line as the far side's shell will see it.
    public let text: String

    fileprivate init(text: String) {
        self.text = text
    }
}
