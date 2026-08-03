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
                let object: [String: Any] = [
                    "name": item.name,
                    "path": item.path,
                    "directory": item.isDirectory,
                    "size": item.size ?? 0,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: object),
                   let line = String(data: data, encoding: .utf8) {
                    Swift.print(line)
                }
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

    /// Diagnostics go to stderr so `macscp-cli ls --json | jq` stays clean.
    static func note(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
