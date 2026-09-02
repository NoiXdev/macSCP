import Foundation

/// Lists and filters an in-memory set of stored sessions and groups — the
/// value behind the CLI's `sessions` subcommand and, later, shell
/// completion. Pure: no file access, no Keychain, no network. Both callers
/// read through this one value so a filter rule, and the display order, are
/// answered exactly once rather than twice.
///
/// `Row` carries nothing a secret could hide behind: no `keyPath`, no
/// `loginSetID`, no secret id of any shape. A CLI subcommand prints rows to
/// stdout and a completion source echoes them into a shell's own history —
/// both are places a stray field would leak a private-key path or a
/// Keychain handle to whoever can read a terminal scrollback, so the type
/// simply does not carry one, rather than trusting every future caller to
/// scrub it by hand.
public struct SessionCatalog: Sendable {
    /// AND-combined; a `nil` field imposes no constraint.
    public struct Filter: Sendable, Equatable {
        public var group: String?
        public var kind: ConnectionKind?
        public var name: String?
        public var tag: String?

        public init(
            group: String? = nil, kind: ConnectionKind? = nil,
            name: String? = nil, tag: String? = nil
        ) {
            self.group = group
            self.kind = kind
            self.name = name
            self.tag = tag
        }
    }

    /// One session, described with nothing a secret could hide behind.
    public struct Row: Sendable, Equatable {
        public let name: String
        public let kind: ConnectionKind
        /// "Work / Prod" — ancestors first, joined by " / "; empty for top level.
        public let groupPath: String
        public let tags: [String]
        /// Per kind: `user@host:port` (SSH, port always shown), `bucket @
        /// endpoint` (S3), the URL (WebDAV).
        public let target: String
    }

    private let sessions: [StoredSession]
    private let groups: [StoredGroup]

    public init(sessions: [StoredSession], groups: [StoredGroup]) {
        self.sessions = sessions
        self.groups = groups
    }

    /// Every session matching `filter`, in the sidebar's own order.
    ///
    /// The order is not reinvented here: `SidebarOrdering.children(of:in:)`
    /// already derives it (position first, folders before sessions on a
    /// tie, input order below that), so this walks that same function
    /// depth-first — recursing into a group in place of listing it, since a
    /// `Row` names a session, never a folder — rather than sorting the flat
    /// session list by some second rule that could disagree with what the
    /// sidebar shows.
    public func rows(matching filter: Filter) -> [Row] {
        let tree = SidebarOrdering.Tree(groups: groups, sessions: sessions)
        // `uniqueKeysWithValues:` traps the whole process on a duplicate id —
        // not a graceful failure a caller can catch, a crash. A store file
        // written or merged by two installations (or corrupted by hand) can
        // carry a duplicated UUID; `uniquingKeysWith:` keeps the FIRST
        // occurrence instead, matching this array's own iteration order,
        // rather than letting one bad record take the CLI down
        // (final-branch-review finding, 2026-09-02).
        let sessionsByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groupsByID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var ordered: [(session: StoredSession, ancestry: [String])] = []
        func walk(parentID: UUID?, ancestry: [String]) {
            for item in SidebarOrdering.children(of: parentID, in: tree) {
                switch item {
                case .group(let id):
                    guard let group = groupsByID[id] else { continue }
                    walk(parentID: id, ancestry: ancestry + [group.name])
                case .session(let id):
                    guard let session = sessionsByID[id] else { continue }
                    ordered.append((session, ancestry))
                }
            }
        }
        walk(parentID: nil, ancestry: [])

        return ordered
            .filter { matches($0.session, ancestry: $0.ancestry, filter: filter) }
            .map { row(for: $0.session, ancestry: $0.ancestry) }
    }

    private func matches(_ session: StoredSession, ancestry: [String], filter: Filter) -> Bool {
        if let kind = filter.kind, session.kind != kind { return false }
        if let name = filter.name, !session.name.localizedCaseInsensitiveContains(name) {
            return false
        }
        if let tag = filter.tag,
           !session.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            return false
        }
        if let group = filter.group,
           !ancestry.contains(where: { $0.caseInsensitiveCompare(group) == .orderedSame }) {
            return false
        }
        return true
    }

    private func row(for session: StoredSession, ancestry: [String]) -> Row {
        Row(
            name: session.name,
            kind: session.kind,
            groupPath: ancestry.joined(separator: " / "),
            tags: session.tags,
            target: target(for: session))
    }

    /// A missing block (`ssh`/`s3`/`webdav` all `nil` on `kind`'s own
    /// backend) answers `""` rather than inventing a target, for every kind
    /// alike — not just because a blockless record is reachable (`SessionStore`
    /// drops a blockless `.ssh` record on load, but has no such drop for
    /// `.s3`/`.webdav`; `SessionStore.swift` ~96-112), but because those two
    /// backends never had inventing accessors to begin with: a missing block
    /// there has always been "the empty bag", the same term that hygiene
    /// comment uses. `""` continues that answer instead of introducing a
    /// fabricated host/bucket/URL placeholder alongside it.
    private func target(for session: StoredSession) -> String {
        switch session.kind {
        case .ssh:
            guard let ssh = session.ssh else { return "" }
            return "\(ssh.username)@\(ssh.host):\(ssh.port)"
        case .s3:
            guard let s3 = session.s3 else { return "" }
            return "\(s3.bucket) @ \(s3.endpoint)"
        case .webdav:
            guard let webdav = session.webdav else { return "" }
            return webdav.baseURL
        }
    }
}
