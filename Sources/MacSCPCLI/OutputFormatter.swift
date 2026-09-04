import Foundation
import macSCPCore

/// The format is switched ONLY by `--json`, never by the presence of a TTY.
/// Tying it to a TTY would mean `macscp-cli ls prod:/ > list.txt` silently
/// produces something different from the same command without redirection —
/// a trap you only notice once a script has written the wrong file.
enum OutputFormatter {
    static func print(items: [RemoteFileItem], asJSON: Bool) {
        if asJSON {
            for item in items {
                // `null`, not `0`, when the size is unknown — collapsing the
                // two would make an empty file and an unreported size look
                // identical to a `jq` consumer (M20 final-review minor).
                let object: [String: Any] = [
                    "name": item.name,
                    "path": item.path,
                    "directory": item.isDirectory,
                    "size": item.size.map { $0 as Any } ?? NSNull(),
                ]
                print(json: object)
            }
        } else {
            let formatter = ByteCountFormatter()
            for item in items {
                let size = item.isDirectory
                    ? "-"
                    : item.size.map { formatter.string(fromByteCount: Int64($0)) } ?? "-"
                Swift.print("\(item.name)\(item.isDirectory ? "/" : "")\t\(size)")
            }
        }
    }

    static func print(rows: [SessionCatalog.Row], asJSON: Bool) {
        if asJSON {
            for row in rows {
                // Unlike `items:`'s `size`, neither field here has a
                // "known but absent" state to distinguish from "empty by
                // construction" — `groupPath` is already `""` for a
                // top-level session and `tags` is already `[]` for an
                // untagged one (`SessionCatalog.Row`'s own values, not a
                // placeholder standing in for something unread), so both
                // serialize as their own empty value rather than `null`.
                let object: [String: Any] = [
                    "name": row.name,
                    "kind": row.kind.rawValue,
                    "target": row.target,
                    "group": row.groupPath,
                    "tags": row.tags,
                ]
                print(json: object)
            }
        } else {
            for row in rows {
                Swift.print(
                    "\(row.name)\t\(row.kind.rawValue)\t\(row.target)\t\(row.groupPath)\t"
                        + row.tags.joined(separator: ","))
            }
        }
    }

    /// One diagnosis row, printed the moment its step lands — `diagnose`
    /// hands this to `ConnectionDiagnostics.run(scope:onStep:)`, whose whole
    /// reason for existing is that a trace can spend twenty seconds after
    /// the rows above it are already known.
    ///
    /// Every word comes from `DiagnoseRendering`; nothing about a row's
    /// wording is decided here. A text step can be several lines — a trace
    /// prints one row per hop under its own — which is why this takes the
    /// step and not a string.
    static func print(step: DiagnosticStep, asJSON: Bool) {
        if asJSON {
            print(json: DiagnoseRendering.jsonObject(for: step))
        } else {
            for row in DiagnoseRendering.textRows(for: step) { Swift.print(row) }
        }
    }

    /// One object, one line — the JSON-lines shape every `--json` in this
    /// CLI writes, and the one place the serialization is spelled.
    ///
    /// Silent on a serialization failure, which is what the two bodies above
    /// did with their own copies of these four lines before this was
    /// extracted: `JSONSerialization` refuses only a non-JSON value, every
    /// caller here builds its object out of `String`/`Int`/`Bool`/`NSNull`
    /// and arrays and dictionaries of those, and a `try!` would turn a
    /// hypothetical future mistake into a crash mid-listing.
    static func print(json object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object),
           let line = String(data: data, encoding: .utf8) {
            Swift.print(line)
        }
    }

    /// Diagnostics go to stderr so `macscp-cli ls --json | jq` stays clean.
    static func note(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
