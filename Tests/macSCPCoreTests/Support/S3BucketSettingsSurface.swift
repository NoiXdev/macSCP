import Foundation
import MacSCPTestSupport

/// The method surface of `S3BucketSettings`, read from the source rather than
/// retyped: the protocol's own requirements, and the methods of any
/// extension of it declared in the SAME file (`S3BucketSettings.swift`, the
/// only file read). An extension of the protocol in another file is not on
/// the scanned surface.
///
/// It exists for one guard (`S3ObjectLockTests`): there must be no way, on
/// this capability, to enable Object Lock on an existing bucket, which was
/// not asked for and cannot be undone. The rig accepts that request, so no
/// test against the rig can show the absence; a scan of what the protocol
/// offers can. A literal list of method names in a test would be a second
/// copy that a rename leaves behind, so the names come from the declaration.
///
/// Read through `SourceCorpus.code(of:)`, which blanks comments and string
/// literals, so a doc comment that quotes a method (this protocol's own
/// comment names `setObjectLockDefault`) is not mistaken for one.
enum S3BucketSettingsSurface {
    /// `name(label:label:)` for every method declared by the protocol or by
    /// an extension of it, in source order. A parameter with no label is
    /// `_`, as in `setLegalHold(_:ofKey:inBucket:versionId:)`.
    static var methodNames: [String] {
        get throws {
            let url = SourceCorpus.url(of: .sources)
                .appendingPathComponent("macSCPCore/RemoteFS/S3BucketSettings.swift")
            return methodNames(inCode: try SourceCorpus.code(of: url))
        }
    }

    /// The scan itself, on code whose comments and strings are already
    /// blanked. Separate so a test can drive it with a planted declaration
    /// and show it flags one: a scan that has never been seen to find
    /// anything is a comment that runs.
    static func methodNames(inCode code: String) -> [String] {
        let chars = Array(code)
        var names: [String] = []
        for body in declarationBodies(in: chars) {
            names += methods(in: Array(chars[body]))
        }
        return names
    }

    /// The ranges between the braces of every `protocol S3BucketSettings`
    /// and `extension S3BucketSettings`.
    private static func declarationBodies(in chars: [Character]) -> [Range<Int>] {
        var bodies: [Range<Int>] = []
        for keyword in ["protocol", "extension"] {
            let header = Array(keyword + " S3BucketSettings")
            var i = 0
            while i + header.count <= chars.count {
                guard Array(chars[i..<(i + header.count)]) == header,
                    isBoundary(chars, before: i), isBoundary(chars, after: i + header.count - 1)
                else {
                    i += 1
                    continue
                }
                guard let open = chars[i...].firstIndex(of: "{"),
                    let close = matching(chars, open: open, with: "{", "}")
                else { break }
                bodies.append((open + 1)..<close)
                i = close
            }
        }
        return bodies
    }

    /// The `func`s at the top level of one declaration body (a function's own
    /// body is skipped, so a local `func` inside a default implementation is
    /// not part of the surface).
    private static func methods(in body: [Character]) -> [String] {
        var names: [String] = []
        var depth = 0
        var i = 0
        let keyword = Array("func")
        while i < body.count {
            let c = body[i]
            if c == "{" { depth += 1 }
            if c == "}" { depth -= 1 }
            if depth == 0, i + 4 < body.count, Array(body[i..<(i + 4)]) == keyword,
                isBoundary(body, before: i), body[i + 4].isWhitespace
            {
                var j = i + 4
                while j < body.count, body[j].isWhitespace { j += 1 }
                var name = ""
                while j < body.count, body[j].isLetter || body[j].isNumber || body[j] == "_" {
                    name.append(body[j])
                    j += 1
                }
                if j < body.count, body[j] == "<", let end = matching(body, open: j, with: "<", ">") {
                    j = end + 1
                }
                while j < body.count, body[j].isWhitespace { j += 1 }
                if !name.isEmpty, j < body.count, body[j] == "(",
                    let close = matching(body, open: j, with: "(", ")")
                {
                    names.append("\(name)(\(labels(of: Array(body[(j + 1)..<close]))))")
                    i = close
                }
            }
            i += 1
        }
        return names
    }

    /// `label:label:` for a parameter list, split at its top-level commas.
    private static func labels(of parameters: [Character]) -> String {
        var result = ""
        var parts: [String] = []
        var current = ""
        var depth = 0
        var i = 0
        while i < parameters.count {
            let c = parameters[i]
            // `->` inside a function type is not an angle bracket.
            if c == "-", i + 1 < parameters.count, parameters[i + 1] == ">" {
                current += "->"
                i += 2
                continue
            }
            if "([<".contains(c) { depth += 1 }
            if ")]>".contains(c) { depth -= 1 }
            if c == ",", depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(current) }
        for part in parts {
            let head = part.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0]
            if let label = head.split(whereSeparator: { $0.isWhitespace }).first {
                result += "\(label):"
            }
        }
        return result
    }

    private static func isBoundary(_ chars: [Character], before index: Int) -> Bool {
        index == 0 || !(chars[index - 1].isLetter || chars[index - 1].isNumber || chars[index - 1] == "_")
    }

    private static func isBoundary(_ chars: [Character], after index: Int) -> Bool {
        index + 1 >= chars.count
            || !(chars[index + 1].isLetter || chars[index + 1].isNumber || chars[index + 1] == "_")
    }

    /// The index of the bracket that closes the one at `open`.
    private static func matching(
        _ chars: [Character], open: Int, with opening: Character, _ closing: Character
    ) -> Int? {
        var depth = 0
        var i = open
        while i < chars.count {
            // `->` is not a closing angle bracket.
            if chars[i] == "-", i + 1 < chars.count, chars[i + 1] == ">" {
                i += 2
                continue
            }
            if chars[i] == opening { depth += 1 }
            if chars[i] == closing {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }
}
