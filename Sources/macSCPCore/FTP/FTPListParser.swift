import Foundation

/// A listing line that no reader knows how to read.
///
/// Thrown for the whole directory, never swallowed per line: a parser that
/// dropped the lines it could not read would show the user a folder with
/// files missing and say nothing, and a comparison or a sync built on that
/// listing would act on the gap. `index` is the position in the array that was
/// passed in, empty lines included.
///
/// **The payload is deliberately free of server-supplied text**, for the same
/// reason as `FTPReplyError`: a failed `#expect` and the default description
/// of an error both print the payload, and a file name is not for a log.
enum FTPListRefusal: Error, Equatable, Sendable {
    case unreadableLine(index: Int)
}

/// Turns the lines of a directory listing into `RemoteFileItem` values.
///
/// A pure function over bytes: no socket, no connection state. The caller
/// splits the data channel into lines and drops their terminators.
///
/// **Two failure modes, kept apart on purpose.**
/// - A NAME whose bytes are not valid UTF-8 is read as Latin-1 instead, for
///   that name alone. This never fails anything: FTP predates a mandatory
///   encoding, and one legacy file name must not void a whole folder.
/// - A LINE in no dialect this file knows throws
///   `FTPListRefusal.unreadableLine(index:)` and fails that directory.
/// Merging them would either swallow dialect failures or void a listing over
/// one odd byte, so they share no code path: decoding is `decodeName`, which
/// cannot fail, and refusal is a `throw` at the point a line fails to parse.
///
/// Timestamps are best-effort. A `LIST` time carries no zone, so it is read as
/// UTC; one without a year is placed in the most recent year that does not put
/// it in the future. Nothing that compares two folders reads a timestamp.
enum FTPListParser {
    // MARK: MLSD (RFC 3659 section 7)

    /// Reads `MLSD` lines: `fact=value;fact=value; name`.
    ///
    /// The name is everything after the FIRST space, verbatim: it may contain
    /// spaces and semicolons, and the fact block cannot, so that is the only
    /// split that is always right.
    static func mlsd(_ lines: [Data], at directory: String) throws -> [RemoteFileItem] {
        var items: [RemoteFileItem] = []
        for (index, line) in lines.enumerated() {
            let raw = [UInt8](line)
            if isEmptyLine(raw) { continue }
            guard let space = raw.firstIndex(of: 0x20) else {
                throw FTPListRefusal.unreadableLine(index: index)
            }
            let facts = try parseFacts(raw[..<space], index: index)
            guard let type = facts["type"] else {
                throw FTPListRefusal.unreadableLine(index: index)
            }
            let name = decodeName(raw[(space + 1)...])
            let lowered = type.lowercased()
            // The listed directory itself and its parent: not entries.
            if lowered == "cdir" || lowered == "pdir" { continue }
            guard isUsableName(name) else { throw FTPListRefusal.unreadableLine(index: index) }
            if name == "." || name == ".." { continue }

            let kind: RemoteFileKind
            switch lowered {
            case "file": kind = .file
            case "dir": kind = .directory
            case "os.unix=symlink": kind = .symlink
            case _ where lowered.hasPrefix("os.unix=slink"): kind = .symlink
            default: kind = .other
            }
            items.append(
                RemoteFileItem(
                    name: name,
                    path: RemotePath.join(directory, name),
                    kind: kind,
                    size: kind == .file ? facts["size"].flatMap { UInt64($0) } : nil,
                    modifiedAt: facts["modify"].flatMap(parseMLSDTime),
                    permissions: facts["unix.mode"].flatMap { UInt32($0, radix: 8) }
                        .map { $0 & 0o7777 },
                    owner: facts["unix.owner"] ?? facts["unix.uid"],
                    group: facts["unix.group"] ?? facts["unix.gid"]))
        }
        return items
    }

    /// The fact block, lower-cased by name. A fact with no `=` is not a fact.
    private static func parseFacts(_ block: ArraySlice<UInt8>, index: Int) throws -> [String: String] {
        var facts: [String: String] = [:]
        for part in block.split(separator: 0x3B, omittingEmptySubsequences: true) {
            // Split at the FIRST `=`: `type=OS.unix=symlink` has two.
            guard let eq = part.firstIndex(of: 0x3D), eq > part.startIndex else {
                throw FTPListRefusal.unreadableLine(index: index)
            }
            let key = decodeName(part[..<eq]).lowercased()
            facts[key] = decodeName(part[(eq + 1)...])
        }
        return facts
    }

    // MARK: LIST (Unix and DOS/IIS)

    /// Reads `LIST` lines. Each line is tried as the Unix form, then as the
    /// DOS form; a line that is neither is refused rather than guessed at.
    static func list(
        _ lines: [Data], at directory: String, now: Date = Date()
    ) throws -> [RemoteFileItem] {
        var items: [RemoteFileItem] = []
        for (index, line) in lines.enumerated() {
            let raw = [UInt8](line)
            // An empty line and the `total N` summary are not entries.
            if isEmptyLine(raw) { continue }
            if raw.starts(with: Array("total ".utf8)) { continue }

            let parsed: ParsedLine?
            if let first = raw.first, "-dlbcps".utf8.contains(first) {
                parsed = parseUnix(raw, now: now)
            } else if let first = raw.first, (0x30...0x39).contains(first) {
                parsed = parseDOS(raw)
            } else {
                parsed = nil
            }
            guard let entry = parsed, isUsableName(entry.name) else {
                throw FTPListRefusal.unreadableLine(index: index)
            }
            if entry.name == "." || entry.name == ".." { continue }
            items.append(
                RemoteFileItem(
                    name: entry.name,
                    path: RemotePath.join(directory, entry.name),
                    kind: entry.kind,
                    size: entry.kind == .file ? entry.size : nil,
                    modifiedAt: entry.modifiedAt,
                    permissions: entry.permissions,
                    owner: entry.owner,
                    group: entry.group))
        }
        return items
    }

    private struct ParsedLine {
        var name: String
        var kind: RemoteFileKind
        var size: UInt64?
        var modifiedAt: Date?
        var permissions: UInt32?
        var owner: String?
        var group: String?
    }

    /// `drwxr-xr-x   2 owner group   4096 Jan  5  2024 name`
    /// `-rw-r--r--   1 owner group   2048 Jan  5 13:40 name`
    private static func parseUnix(_ raw: [UInt8], now: Date) -> ParsedLine? {
        var cursor = Cursor(raw)
        guard let mode = cursor.token(), mode.count >= 10 else { return nil }
        let kind: RemoteFileKind
        switch mode[0] {
        case UInt8(ascii: "-"): kind = .file
        case UInt8(ascii: "d"): kind = .directory
        case UInt8(ascii: "l"): kind = .symlink
        default: kind = .other
        }
        // Nine permission characters; an eleventh (`+`, `@`, `.`) marks an
        // ACL or a security context and carries no bits.
        guard let permissions = unixPermissions(Array(mode[1..<10])) else { return nil }
        guard mode.count == 10 || mode.count == 11 else { return nil }

        guard let links = cursor.token(), links.allSatisfy(isDigit),
            let owner = cursor.token(), let group = cursor.token(),
            let sizeToken = cursor.token(), sizeToken.allSatisfy(isDigit),
            let month = cursor.token().flatMap(monthNumber),
            let dayToken = cursor.token(), dayToken.allSatisfy(isDigit),
            let day = Int(decodeName(dayToken)),
            let yearOrTime = cursor.token()
        else { return nil }
        guard let nameBytes = cursor.restAfterOneSpace(), !nameBytes.isEmpty else { return nil }

        var nameSlice = nameBytes
        if kind == .symlink, let arrow = firstRange(of: Array(" -> ".utf8), in: nameBytes) {
            nameSlice = nameBytes[..<arrow.lowerBound]
        }
        return ParsedLine(
            name: decodeName(nameSlice),
            kind: kind,
            size: UInt64(decodeName(sizeToken)),
            modifiedAt: unixDate(month: month, day: day, yearOrTime: yearOrTime, now: now),
            permissions: permissions,
            owner: decodeName(owner),
            group: decodeName(group))
    }

    /// `01-05-24  01:40PM       <DIR>          name`
    /// `01-05-2024  01:40PM            1234 name`
    private static func parseDOS(_ raw: [UInt8]) -> ParsedLine? {
        var cursor = Cursor(raw)
        guard let date = cursor.token(), let time = cursor.token(),
            let sizeOrDir = cursor.token()
        else { return nil }
        let dateParts = date.split(separator: UInt8(ascii: "-"), omittingEmptySubsequences: false)
        guard dateParts.count == 3, dateParts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isDigit) }),
            let month = Int(decodeName(dateParts[0])), let day = Int(decodeName(dateParts[1])),
            var year = Int(decodeName(dateParts[2]))
        else { return nil }
        // Two-digit years: a convention, not something the format dictates --
        // 70-99 are read as the 1900s and 00-69 as the 2000s.
        if dateParts[2].count <= 2 { year += year >= 70 ? 1900 : 2000 }

        guard let clock = dosClock(time) else { return nil }
        let isDirectory = sizeOrDir.elementsEqual("<DIR>".utf8)
        var size: UInt64?
        if !isDirectory {
            guard sizeOrDir.allSatisfy(isDigit) else { return nil }
            size = UInt64(decodeName(sizeOrDir))
        }
        // IIS pads with a variable run of spaces, so a name's own leading
        // spaces cannot be told from the padding and are not preserved.
        guard let nameBytes = cursor.restAfterSpaces(), !nameBytes.isEmpty else { return nil }
        return ParsedLine(
            name: decodeName(nameBytes),
            kind: isDirectory ? .directory : .file,
            size: size,
            modifiedAt: utcDate(
                year: year, month: month, day: day, hour: clock.hour, minute: clock.minute),
            permissions: nil, owner: nil, group: nil)
    }

    // MARK: Shared pieces

    /// UTF-8 when the bytes are valid UTF-8, otherwise Latin-1. Cannot fail:
    /// every byte is a Latin-1 scalar.
    private static func decodeName<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let array = Array(bytes)
        if let utf8 = String(validating: array, as: UTF8.self) { return utf8 }
        return String(String.UnicodeScalarView(array.map { Unicode.Scalar($0) }))
    }

    /// A name that can be appended to the listed directory's path. Empty
    /// names and names carrying a path separator or NUL are refused: the
    /// server controls this text, and `../x` joined onto a directory is not
    /// an entry of that directory.
    private static func isUsableName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.unicodeScalars.contains("\0")
    }

    /// An EMPTY line, and only that. A trailing line terminator in a data
    /// stream routinely leaves one at the end, so it is not an entry and not
    /// a malformation. A run of spaces is not a terminator artefact but a
    /// damaged entry, and the single line " " is an empty fact block, a space
    /// and an empty name, which is refused -- so both readers refuse it. The
    /// same goes for a lone CR left behind by a splitter that breaks on LF.
    private static func isEmptyLine(_ raw: [UInt8]) -> Bool { raw.isEmpty }

    private static func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }

    private static func unixPermissions(_ chars: [UInt8]) -> UInt32? {
        guard chars.count == 9 else { return nil }
        var bits: UInt32 = 0
        // (read, write, execute) offsets per class, and the special bit that
        // class's execute slot can carry.
        let special: [UInt32] = [0o4000, 0o2000, 0o1000]
        for group in 0..<3 {
            let r = chars[group * 3], w = chars[group * 3 + 1], x = chars[group * 3 + 2]
            let shift = UInt32(6 - group * 3)
            switch r {
            case UInt8(ascii: "r"): bits |= 0o4 << shift
            case UInt8(ascii: "-"): break
            default: return nil
            }
            switch w {
            case UInt8(ascii: "w"): bits |= 0o2 << shift
            case UInt8(ascii: "-"): break
            default: return nil
            }
            switch x {
            case UInt8(ascii: "x"): bits |= 0o1 << shift
            case UInt8(ascii: "-"): break
            case UInt8(ascii: "s") where group < 2, UInt8(ascii: "t") where group == 2:
                bits |= (0o1 << shift) | special[group]
            case UInt8(ascii: "S") where group < 2, UInt8(ascii: "T") where group == 2:
                bits |= special[group]
            default: return nil
            }
        }
        return bits
    }

    private static func monthNumber(_ token: [UInt8]) -> Int? {
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        return names.firstIndex(of: decodeName(token).lowercased()).map { $0 + 1 }
    }

    /// `2024` or `13:40`. Without a year, the most recent year that does not
    /// put the date more than a day past `now` (`ls` prints the time form for
    /// files from the last six months, and a clock skew can push one slightly
    /// ahead). A February 29th is searched back to a leap year.
    private static func unixDate(month: Int, day: Int, yearOrTime: [UInt8], now: Date) -> Date? {
        let text = decodeName(yearOrTime)
        if !text.contains(":") {
            guard yearOrTime.count == 4, yearOrTime.allSatisfy(isDigit), let year = Int(text) else {
                return nil
            }
            return utcDate(year: year, month: month, day: day, hour: 0, minute: 0)
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return nil
        }
        let nowYear = utcCalendar.component(.year, from: now)
        let limit = now.addingTimeInterval(86_400)
        for year in stride(from: nowYear, through: nowYear - 8, by: -1) {
            if let date = utcDate(year: year, month: month, day: day, hour: hour, minute: minute),
                date <= limit
            {
                return date
            }
        }
        return nil
    }

    /// `01:40PM`, `12:05AM`, or a 24-hour `13:40` some servers send.
    private static func dosClock(_ token: [UInt8]) -> (hour: Int, minute: Int)? {
        var text = decodeName(token).uppercased()
        var meridiem: String?
        if text.hasSuffix("AM") || text.hasSuffix("PM") {
            meridiem = String(text.suffix(2))
            text.removeLast(2)
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, var hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return nil
        }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem == "PM" ? 12 : 0)
        }
        return (hour, minute)
    }

    /// `YYYYMMDDHHMMSS` with an optional `.sss` fraction, always UTC.
    private static func parseMLSDTime(_ value: String) -> Date? {
        let whole = value.prefix { $0 != "." }
        guard whole.count == 14, whole.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let digits = Array(whole).map { Int(String($0))! }
        func number(_ range: Range<Int>) -> Int { digits[range].reduce(0) { $0 * 10 + $1 } }
        guard
            var date = utcDate(
                year: number(0..<4), month: number(4..<6), day: number(6..<8),
                hour: number(8..<10), minute: number(10..<12), second: number(12..<14))
        else { return nil }
        if value.contains("."), let fraction = Double("0" + value[value.firstIndex(of: ".")!...]) {
            date.addTimeInterval(fraction)
        }
        return date
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// `nil` unless the components name a real moment: Calendar rolls an
    /// impossible date (a February 30th) forward silently, so the result is
    /// read back and compared.
    private static func utcDate(
        year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int = 0
    ) -> Date? {
        let components = DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = utcCalendar.date(from: components) else { return nil }
        let back = utcCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        guard back.year == year, back.month == month, back.day == day, back.hour == hour,
            back.minute == minute, back.second == second
        else { return nil }
        return date
    }

    private static func firstRange(of needle: [UInt8], in haystack: ArraySlice<UInt8>)
        -> Range<Int>?
    {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in haystack.startIndex...(haystack.endIndex - needle.count)
        where haystack[start..<start + needle.count].elementsEqual(needle) {
            return start..<start + needle.count
        }
        return nil
    }

    /// A left-to-right reader over a line's bytes.
    private struct Cursor {
        let bytes: [UInt8]
        var position = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        /// The next run of non-space bytes, after skipping spaces.
        mutating func token() -> [UInt8]? {
            while position < bytes.count, bytes[position] == 0x20 { position += 1 }
            guard position < bytes.count else { return nil }
            let start = position
            while position < bytes.count, bytes[position] != 0x20 { position += 1 }
            return Array(bytes[start..<position])
        }

        /// Everything after exactly ONE space: a Unix name keeps its own
        /// leading and inner spaces. `nil` when no space follows.
        mutating func restAfterOneSpace() -> ArraySlice<UInt8>? {
            guard position < bytes.count, bytes[position] == 0x20 else { return nil }
            return bytes[(position + 1)...]
        }

        /// Everything after a run of spaces.
        mutating func restAfterSpaces() -> ArraySlice<UInt8>? {
            while position < bytes.count, bytes[position] == 0x20 { position += 1 }
            guard position < bytes.count else { return nil }
            return bytes[position...]
        }
    }
}
