import Foundation

/// A group of manual sessions sharing the same effective login (M10b spec
/// §4) — the "merge into one set?" suggestion the UI banners.
public struct LoginMergeCandidate: Equatable, Sendable {
    public var username: String
    public var authKind: StoredSession.AuthKind
    public var keyPath: String?
    public var sessionIDs: [UUID]

    public init(
        username: String, authKind: StoredSession.AuthKind, keyPath: String?, sessionIDs: [UUID]
    ) {
        self.username = username
        self.authKind = authKind
        self.keyPath = keyPath
        self.sessionIDs = sessionIDs
    }
}

/// Grouping key for equality detection: two sessions merge only if every
/// field here matches. `.privateKey` sessions never carry a password, so
/// `password` stays nil for them; `.password` sessions never carry a
/// keyPath.
private struct LoginGroupKey: Hashable {
    var username: String
    var authKind: StoredSession.AuthKind
    var keyPath: String?
    var password: String?
}

/// Pure equality detection over MANUAL sessions (loginSetID == nil).
/// Password values are compared in memory only and never leave this
/// function; sessions without a stored password do not participate.
public enum LoginMergePlanner {
    public static func candidates(
        sessions: [StoredSession], ignoredGroups: [Set<UUID>], secrets: any SecretStore
    ) -> [LoginMergeCandidate] {
        // `order` tracks first-seen order of each key so ties fall back to
        // input order deterministically; `groups` accumulates session ids in
        // the order sessions were encountered.
        var order: [LoginGroupKey] = []
        var groups: [LoginGroupKey: [UUID]] = [:]

        for session in sessions where session.loginSetID == nil {
            let key: LoginGroupKey
            switch session.authKind {
            case .privateKey:
                key = LoginGroupKey(
                    username: session.username, authKind: .privateKey,
                    keyPath: session.keyPath, password: nil)
            case .password:
                // A session with no keychain entry has nothing to compare
                // against another session's password, so it cannot
                // participate in a merge suggestion at all.
                guard let password = (try? secrets.password(for: session.id)) ?? nil else {
                    continue
                }
                key = LoginGroupKey(
                    username: session.username, authKind: .password,
                    keyPath: nil, password: password)
            }
            if groups[key] == nil {
                order.append(key)
            }
            groups[key, default: []].append(session.id)
        }

        let candidates: [LoginMergeCandidate] = order.compactMap { key in
            guard let sessionIDs = groups[key], sessionIDs.count >= 2 else { return nil }
            let idSet = Set(sessionIDs)
            // A candidate that's already fully covered by a previously
            // ignored group (same ids, or a superset) stays suppressed until
            // a new member makes it no longer a subset.
            if ignoredGroups.contains(where: { idSet.isSubset(of: $0) }) { return nil }
            return LoginMergeCandidate(
                username: key.username, authKind: key.authKind, keyPath: key.keyPath,
                sessionIDs: sessionIDs)
        }

        return candidates.sorted { a, b in
            let usernameOrder = a.username.localizedCaseInsensitiveCompare(b.username)
            if usernameOrder != .orderedSame { return usernameOrder == .orderedAscending }
            let keyPathOrder = (a.keyPath ?? "").compare(b.keyPath ?? "")
            if keyPathOrder != .orderedSame { return keyPathOrder == .orderedAscending }
            return a.sessionIDs.count < b.sessionIDs.count
        }
    }
}
