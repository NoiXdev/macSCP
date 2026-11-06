/// Why a path or a command argument was refused before it could reach an FTP
/// command line.
///
/// **The payload is a character CLASS, never the offending text.** The class
/// is what a reader has to act on ("this name carries a line break"), and the
/// path itself is the caller's to report if it wants to: a refusal that
/// carried the string would put it into every error description and into the
/// source text `#expect` prints, and the arguments this type guards include
/// the one `PASS` carries.
enum FTPPathRefusal: Error, Equatable, Sendable {
    case forbiddenCharacter(FTPPath.ForbiddenCharacter)
}

/// The single choke point between a path and a command line (Review Focus 1
/// of the FTP plan).
///
/// An FTP command line is terminated by CR LF (RFC 959 section 5.3), so a
/// path carrying one does not travel as a path: everything after the CR LF is
/// a second command, chosen by whoever named the file. `FTPControlConnection`
/// writes exactly one command line, in one function, and that function takes
/// both the verb and the argument through `validated(_:)` — so there is no
/// second route onto the wire to keep in step with this one.
///
/// It is a filter, not a transformer: a clean path comes back byte for byte.
/// Nothing is escaped, quoted or stripped, because there is no escaping in
/// FTP's command grammar to escape into — a line break in an argument is
/// unrepresentable, not merely awkward, and a validator that "fixed" one
/// would be renaming the user's file for them.
enum FTPPath {
    /// A character class that may not cross into a command line.
    enum ForbiddenCharacter: String, Sendable, CaseIterable, Equatable {
        /// CR, the first half of a command terminator.
        case carriageReturn
        /// LF. Refused on its own account: a server that splits lines at LF
        /// alone (many do) is injectable with no CR at all.
        case lineFeed
        /// NUL. The byte path from here to a server's own parser is not all
        /// Swift, and a NUL ends a C string wherever it is read as one.
        case nul

        var scalar: Unicode.Scalar {
            switch self {
            case .carriageReturn: "\u{0D}"
            case .lineFeed: "\u{0A}"
            case .nul: "\u{00}"
            }
        }

        /// This refusal's catalog key, DERIVED from the case rather than
        /// spelled at each site that renders it. A case added without its
        /// four catalog entries is caught by
        /// `FTPPathTests.everyForbiddenCharacterClassHasItsOwnSentence`; the
        /// lookup itself cannot fail loudly, since `CoreL10n.string` falls
        /// back to the key text.
        var messageKey: String { "core.connect.ftpPathForbidden.\(rawValue)" }

        /// The localized sentence for this refusal.
        var message: String { CoreL10n.string(messageKey) }
    }

    /// `path` unchanged, or a refusal naming the first forbidden class it
    /// carries.
    ///
    /// Scanned over `unicodeScalars`, not `Character`s: a `Character` is a
    /// grapheme cluster, and CR LF is ONE of them, equal to neither CR nor
    /// LF. A scan written over characters would therefore let the exact
    /// injection this function exists for straight through. Measured
    /// 2026-11-06 with this program, which prints `characters: 3`,
    /// `contains LF char: false`, `contains CR char: false`, `scalars: 4`:
    ///
    ///     let s = "a\r\nb"
    ///     print("characters:", Array(s).count)
    ///     print("contains LF char:", s.contains("\n"))
    ///     print("contains CR char:", s.contains("\r"))
    ///     print("scalars:", s.unicodeScalars.count)
    static func validated(_ path: String) throws -> String {
        for scalar in path.unicodeScalars {
            if let forbidden = ForbiddenCharacter.allCases.first(where: { $0.scalar == scalar }) {
                throw FTPPathRefusal.forbiddenCharacter(forbidden)
            }
        }
        return path
    }
}
