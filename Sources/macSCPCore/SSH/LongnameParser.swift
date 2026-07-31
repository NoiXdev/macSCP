import Foundation

/// Parses the owner/group NAME fields out of an SFTP listing's `longname` —
/// the server-formatted `ls -l` style line Citadel's `SFTPPathComponent`
/// carries alongside the numeric `uidgid` attribute (M11m/T1).
///
/// `longname` is server-generated and format-dependent: this parser is
/// deliberately defensive rather than clever. It trusts exactly the fixed
/// field positions the `ls -l` format guarantees — permission string, link
/// count, owner, group, in that order — tolerates any run of whitespace
/// between fields, and refuses (`nil`) anything that doesn't clearly look
/// like that shape, rather than guessing at a value that could be wrong.
/// `SFTPAttributeMapper` falls back to the numeric `uidgid` (or `nil`)
/// whenever this returns `nil` — see that type and the M11m design doc's
/// "honest about longname fragility" section.
public enum LongnameParser {
    /// Characters that can legally start an `ls -l` permission field: `-`
    /// (regular file), `d` (directory), `l` (symlink), `b`/`c` (device),
    /// `p` (FIFO), `s` (socket).
    private static let fileTypeCharacters = Set("-dlbcps")

    /// Extracts `(owner, group)` from a `longname` line such as
    /// `-rw-r--r-- 1 www-data staff 2454 Jul 30 14:22 config.php`, or `nil`
    /// if the line doesn't confidently look like that shape.
    public static func ownerGroup(from longname: String) -> (owner: String, group: String)? {
        // `split` with the default `omittingEmptySubsequences: true` already
        // collapses any run of spaces/tabs into a single separator, so
        // multi-whitespace lines need no special handling here.
        let fields = longname.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 4 else { return nil }

        // Field 0: the permission string — exactly 10 characters
        // (type + 3×rwx), starting with a recognized file-type character.
        let permissionField = fields[0]
        guard permissionField.count == 10,
            let firstCharacter = permissionField.first,
            fileTypeCharacters.contains(firstCharacter)
        else { return nil }

        // Field 1: the link count — must be numeric, otherwise this isn't
        // an `ls -l` entry line at all (e.g. a leading "total 8" summary).
        guard Int(fields[1]) != nil else { return nil }

        let owner = String(fields[2])
        let group = String(fields[3])
        guard !owner.isEmpty, !group.isEmpty else { return nil }
        return (owner: owner, group: group)
    }
}
