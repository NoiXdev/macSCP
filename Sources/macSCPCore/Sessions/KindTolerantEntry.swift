import Foundation

/// One element of an export file's array of connection-bearing entries:
/// either a value this build can read, or the raw `kind` name it could not.
///
/// **Why it exists.** `ConnectionKind` is a closed `String`-raw `Codable`,
/// and the FTP backend design (§11a, §13) measured that nothing in `Sources`
/// called `ConnectionKind(rawValue:` at all — so a file naming a kind this
/// build has no case for threw out of the enum's synthesized `init(from:)`,
/// and because an array decode fails with its element, ONE such entry voided
/// the WHOLE document: an older macSCP opening an export that contains an
/// FTP session imported nothing and reported `notAnExportFile`. FTP is the
/// first kind added since export existed, so nothing here had had to survive
/// it before.
///
/// **Why it is here and not on the enum.** `ConnectionKind` stays closed, so
/// every exhaustive `switch` over it stays exhaustive and the JSON session
/// store stays strict — a sessions file naming an unreadable kind is still a
/// refusal, because a store is this machine's own record rather than a
/// document that travelled. The tolerance belongs to the envelope layer
/// alone, which is `SessionExportCodec` and `LoginSetExportCodec`; this type
/// lives in neither, because it is used by both.
///
/// (Withdrawn wording, verbatim: "this type lives in the senior of the two
/// and the other uses it." It lived in `SessionExportCodec.swift` until
/// 2026-11-08, when it moved to this file of its own.)
///
/// The unknown entry is never CONSTRUCTED: only `kind` is read before the
/// decision, so no caller is ever handed an `ExportedSession` or an
/// `ExportedLoginSet` holding a placeholder kind that it has to remember not
/// to trust.
enum KindTolerantEntry<Entry: Decodable>: Decodable {
    case readable(Entry)
    case unknownKind(String)

    private enum KindOnly: String, CodingKey { case kind }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: KindOnly.self),
            let raw = try? container.decodeIfPresent(String.self, forKey: .kind),
            ConnectionKind(rawValue: raw) == nil {
            self = .unknownKind(raw)
            return
        }
        // Three shapes reach here, and all three must behave exactly as they
        // did before this type existed: a readable kind, no `kind` key at all
        // (a payload written before M12, which the import side maps to
        // `.ssh`), and a `kind` that is not a string — which the lenient
        // reads above turn into nil rather than into a skip, so the entry's
        // own decoder refuses it as it always did.
        self = .readable(try Entry(from: decoder))
    }

    /// The entries this build can read and the raw kind names it skipped,
    /// both in file order.
    static func split(_ entries: [Self]) -> (readable: [Entry], skipped: [String]) {
        var readable: [Entry] = []
        var skipped: [String] = []
        for entry in entries {
            switch entry {
            case .readable(let value): readable.append(value)
            case .unknownKind(let raw): skipped.append(raw)
            }
        }
        return (readable, skipped)
    }
}
