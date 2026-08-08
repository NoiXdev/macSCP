import Foundation

/// A group of manual sessions that log in as the same principal (M10b spec §4,
/// generalized to every protocol in M24) — the "merge into one set?"
/// suggestion the UI banners.
public struct LoginMergeCandidate: Equatable, Sendable {
    /// Every session in the group has this kind, and the set a merge creates
    /// gets it. Also part of the grouping key, but that is not what keeps a
    /// group from mixing kinds -- field keys are namespaced (`SSHField.*` vs.
    /// `S3Field.*` etc.), so two backends can never produce equal `fields`
    /// dictionaries to begin with. The actual mixed-group defense is
    /// `SessionListViewModel.applyMerge`'s own kind guard, which is tested;
    /// `kind`'s presence here is structurally untestable.
    public var kind: ConnectionKind
    /// The credential values the group shares, in the backend's own field
    /// vocabulary — the visible non-secret credential fields, and NOTHING
    /// else. Never the secret: this value is handed to the UI and to
    /// `BackendDescriptor.loginSet(id:name:from:)`, and a secret has no
    /// business in either.
    public var values: FieldValues
    /// What to call this login on screen — the first visible non-secret
    /// credential field's value. The user name for SSH and WebDAV, the access
    /// key ID for S3.
    public var displayLabel: String
    public var sessionIDs: [UUID]

    public init(
        kind: ConnectionKind, values: FieldValues, displayLabel: String, sessionIDs: [UUID]
    ) {
        self.kind = kind
        self.values = values
        self.displayLabel = displayLabel
        self.sessionIDs = sessionIDs
    }
}

/// Grouping key: two sessions merge only if every part here matches.
///
/// `fields` holds the visible NON-SECRET credential fields by namespaced key.
/// Which fields those are is the backend's answer, not this file's — SSH shows
/// `keyPath` only under private-key auth, so the same code produces the
/// pre-M24 SSH key without naming SSH. This holds only because
/// `SSHFieldSchema.values(from:)` never writes `SSHField.managedKeyID` (it has
/// no persisted home), so that field enters every private-key grouping key as
/// the constant `""` — an untested-until-now dependency `LoginMergePlannerTests
/// .privateKeyCandidateCarriesManagedKeyIDAsAConstantEmptyString` now pins, so
/// a future writer of `managedKeyID` cannot silently change SSH equivalence.
private struct LoginGroupKey: Hashable {
    var kind: ConnectionKind
    var fields: [String: String]
    var secret: String?
}

/// Pure equality detection over MANUAL sessions (loginSetID == nil).
/// Secret values are compared in memory only and never leave this function.
public enum LoginMergePlanner {
    public static func candidates(
        sessions: [StoredSession], ignoredGroups: [Set<UUID>], secrets: any SecretStore
    ) -> [LoginMergeCandidate] {
        // `order` tracks first-seen order of each key so ties fall back to
        // input order deterministically; `groups` accumulates session ids in
        // the order sessions were encountered.
        var order: [LoginGroupKey] = []
        var groups: [LoginGroupKey: [UUID]] = [:]
        var labels: [LoginGroupKey: String] = [:]
        var credentials: [LoginGroupKey: FieldValues] = [:]

        for session in sessions where session.loginSetID == nil {
            let descriptor = BackendDescriptor.descriptor(for: session.kind)
            // A session whose kind claims a block it does not carry is broken
            // stored data. It has no credentials to compare: `sessionValues`
            // yields the EMPTY bag for it (M26), so without this guard it
            // would group with every other blockless session of its kind on
            // all-empty fields, not on anything the user actually typed.
            guard descriptor.hasStoredConfiguration(session) else { continue }

            let namespace = descriptor.fieldNamespace
            let storedValues = descriptor.sessionValues(session)
            let visible = descriptor.credentialSchema.visibleFields(
                in: storedValues, namespace: namespace)

            var fields: [String: String] = [:]
            var values = FieldValues()
            var label: String?
            for field in visible where !field.isSecret {
                let key = "\(namespace).\(field.id)"
                // Compared VERBATIM, like every part of this key: this asks
                // whether two logins are the same, and a user name differing
                // in case or padding is a different user name. (Distinct from
                // `FieldIdentity`, which answers "same CONNECTION?" for import
                // dedup and which `authKind` does not even carry.)
                let raw = storedValues.raw[key] ?? ""
                fields[key] = raw
                values.setRaw(key, to: raw)
                if label == nil { label = raw }
            }

            var secret: String?
            if let secretField = visible.first(where: \.isSecret) {
                // `.passphrase` unlocks a key file `keyPath` already put in
                // the key, so it neither enters the key nor justifies a
                // Keychain read. A missing role reads as `.credential`: the
                // safe direction, keeping logins apart rather than merging
                // them. And a secret-less session under `.credential` has
                // nothing to compare, so it cannot take part at all -- which
                // is the pre-M24 SSH rule, now applied to every backend.
                if secretField.secretRole != .passphrase {
                    guard let stored = (try? secrets.password(for: session.id)) ?? nil else {
                        continue
                    }
                    secret = stored
                }
            }

            let key = LoginGroupKey(kind: session.kind, fields: fields, secret: secret)
            if groups[key] == nil {
                order.append(key)
                labels[key] = label ?? ""
                credentials[key] = values
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
                kind: key.kind, values: credentials[key] ?? FieldValues(),
                displayLabel: labels[key] ?? "", sessionIDs: sessionIDs)
        }

        return candidates.sorted { a, b in
            let labelOrder = a.displayLabel.localizedCaseInsensitiveCompare(b.displayLabel)
            if labelOrder != .orderedSame { return labelOrder == .orderedAscending }
            // Two protocols can produce the same label; without this the order
            // between them would depend on input order alone.
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            if a.sessionIDs.count != b.sessionIDs.count { return a.sessionIDs.count < b.sessionIDs.count }
            // Final tiebreaker: two candidates can share label, kind AND group
            // size, and `sorted(by:)` is not a stable sort -- without a total
            // order here their relative position is unspecified, so the merge
            // banner could pick a different one of them between launches with
            // identical stored data.
            return a.sessionIDs.lexicographicallyPrecedes(b.sessionIDs)
        }
    }
}
