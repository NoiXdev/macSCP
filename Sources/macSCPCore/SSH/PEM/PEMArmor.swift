import Foundation

/// The envelope around a PEM body: `-----BEGIN <label>-----`, optional
/// RFC 1421 headers, base64, `-----END <label>-----`.
///
/// Nothing here decrypts or parses DER. Splitting the envelope off is what
/// lets the label alone decide which structure the body is, and lets the
/// headers alone decide whether it is encrypted the legacy way.
struct PEMArmor: Equatable, Sendable {
    /// The text between the dashes, e.g. `RSA PRIVATE KEY`.
    let label: String
    /// RFC 1421 headers, keyed by name with the surrounding spaces trimmed.
    /// Empty for every file OpenSSH and LibreSSL write unless the file is
    /// encrypted the legacy way.
    let headers: [String: String]
    /// The decoded base64 body.
    let body: Data

    /// `Proc-Type: 4,ENCRYPTED` with a `DEK-Info` beside it — the legacy
    /// (pre-PKCS#8) way of encrypting a PEM key.
    var isLegacyEncrypted: Bool {
        guard let procType = headers["Proc-Type"] else { return false }
        return procType.contains("ENCRYPTED") && headers["DEK-Info"] != nil
    }

    private static let beginPrefix = "-----BEGIN "
    private static let endPrefix = "-----END "
    private static let boundarySuffix = "-----"
    static let puttyPrefix = "PuTTY-User-Key-File-"

    static func parse(_ text: String) throws(PEMPrivateKeyDecoder.DecodeError) -> PEMArmor {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(puttyPrefix) {
            throw .notReadable(.putty)
        }
        // Both line endings, because a key file copied through Windows keeps
        // its CRLFs and is otherwise a perfectly good key. The empty lines are
        // KEPT: the blank line after the RFC 1421 headers is what ends them,
        // and a split that drops it hands the first base64 line to the header
        // loop.
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var index = lines.startIndex
        while index < lines.endIndex, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            index += 1
        }
        guard index < lines.endIndex else { throw .notPEM }
        let begin = lines[index].trimmingCharacters(in: .whitespaces)
        guard begin.hasPrefix(beginPrefix), begin.hasSuffix(boundarySuffix),
              begin.count > beginPrefix.count + boundarySuffix.count else {
            throw .notPEM
        }
        let label = String(begin.dropFirst(beginPrefix.count).dropLast(boundarySuffix.count))
        index += 1

        // Headers run to the first blank line, and only exist at all when the
        // line right after BEGIN carries a colon. A base64 body never does.
        var headers: [String: String] = [:]
        if index < lines.endIndex, lines[index].contains(":") {
            while index < lines.endIndex {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    index += 1
                    break
                }
                // A line without a colon is already body, and is NOT consumed:
                // consuming it silently swallows the first base64 line, which
                // then shows up much later as a wrong passphrase.
                guard let colon = line.firstIndex(of: ":") else { break }
                index += 1
                let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
        }

        var base64 = ""
        var sawEnd = false
        while index < lines.endIndex {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if line.hasPrefix(endPrefix) {
                guard line == endPrefix + label + boundarySuffix else { throw .notReadable(.malformed) }
                sawEnd = true
                break
            }
            base64 += line
        }
        guard sawEnd else { throw .notReadable(.malformed) }
        guard let body = Data(base64Encoded: base64), body.isEmpty == false else {
            throw .notReadable(.malformed)
        }
        return PEMArmor(label: label, headers: headers, body: body)
    }
}
