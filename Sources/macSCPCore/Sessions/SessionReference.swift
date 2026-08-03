import Foundation

/// A command-line argument that either names a stored session (`prod:/var/www`)
/// or is a plain local path. Parsing and resolution live here rather than in
/// the CLI because the CLI has no test target — and getting this wrong means
/// a script writes to the wrong machine.
public enum SessionReference: Equatable, Sendable {
    case local(path: String)
    case remote(name: String, path: String)
}

public enum SessionReferenceError: Error, Equatable, Sendable {
    case unknown(String)
    case ambiguous(String, count: Int)
}

extension SessionReference {
    /// Splits on the FIRST colon only: remote paths may contain colons.
    /// A one-character prefix is treated as local so a drive letter or a
    /// relative path never gets mistaken for a session name.
    public static func parse(_ text: String) -> SessionReference {
        guard let colon = text.firstIndex(of: ":") else { return .local(path: text) }
        let name = String(text[text.startIndex..<colon])
        guard name.count > 1 else { return .local(path: text) }
        let rest = String(text[text.index(after: colon)...])
        return .remote(name: name, path: rest.isEmpty ? "/" : rest)
    }

    /// Matches by UUID first (stable), then by name (renameable). A duplicate
    /// name is an error rather than a coin flip.
    public func resolve(in sessions: [StoredSession]) throws -> StoredSession {
        switch self {
        case .local(let path):
            throw SessionReferenceError.unknown(path)
        case .remote(let name, _):
            if let id = UUID(uuidString: name), let hit = sessions.first(where: { $0.id == id }) {
                return hit
            }
            let matches = sessions.filter { $0.name == name }
            switch matches.count {
            case 0: throw SessionReferenceError.unknown(name)
            case 1: return matches[0]
            default: throw SessionReferenceError.ambiguous(name, count: matches.count)
            }
        }
    }

    public var path: String {
        switch self {
        case .local(let path): return path
        case .remote(_, let path): return path
        }
    }
}
