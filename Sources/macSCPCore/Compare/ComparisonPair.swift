import Foundation

/// One relative name seen on one or both sides of a comparison.
///
/// `name` is the name as it will be SHOWN, taken from the left side when it
/// exists and from the right otherwise. It is always one side's own spelling,
/// never a normalized form, because a person reads it.
public struct ComparisonPair: Equatable, Sendable {
    public let name: String
    public let left: RemoteFileItem?
    public let right: RemoteFileItem?

    public init(name: String, left: RemoteFileItem?, right: RemoteFileItem?) {
        self.name = name
        self.left = left
        self.right = right
    }
}

public enum ComparisonPairing {
    /// Pairs two listings by name, in two passes.
    ///
    /// Pass 1 pairs byte-identical names. The key is the UTF-8 bytes, not the
    /// `String` itself: Swift's `String` equality is Unicode canonical
    /// equivalence, so a `String` key would merge `ä` with `a` + U+0308 even
    /// where a server holds them as two distinct files.
    ///
    /// Pass 2 pairs what pass 1 left over by the NFC form of the name. A
    /// local listing on macOS hands back NFD and a server usually stored NFC,
    /// and the same file must not appear as two rows.
    ///
    /// Both passes use the same rule: a key pairs only where exactly one left
    /// item and exactly one right item carry it. Where two or more share a
    /// key they are distinct files, and pairing them would be a guess, so
    /// they stay one-sided.
    ///
    /// Case is NOT folded in either pass: two remote names differing only in
    /// case are two files on a case-sensitive server, and folding them would
    /// drop one from the comparison entirely.
    ///
    /// The result is ordered by NFC form, then by UTF-8 bytes, so the view is
    /// stable.
    public static func pairs(
        left: [RemoteFileItem], right: [RemoteFileItem]
    ) -> [ComparisonPair] {
        let exact = pairUniquely(left: left, right: right) { Array($0.name.utf8) }
        let normalized = pairUniquely(
            left: exact.unpairedLeft, right: exact.unpairedRight
        ) { $0.name.precomposedStringWithCanonicalMapping }

        let all = exact.pairs + normalized.pairs
            + normalized.unpairedLeft.map { ComparisonPair(name: $0.name, left: $0, right: nil) }
            + normalized.unpairedRight.map { ComparisonPair(name: $0.name, left: nil, right: $0) }
        return all.sorted(by: ordering)
    }

    /// Pairs the items whose key is carried by exactly one item on each side.
    /// Every other item comes back as unpaired.
    private static func pairUniquely<K: Hashable>(
        left: [RemoteFileItem], right: [RemoteFileItem],
        key: (RemoteFileItem) -> K
    ) -> (pairs: [ComparisonPair], unpairedLeft: [RemoteFileItem], unpairedRight: [RemoteFileItem]) {
        let leftByKey = Dictionary(grouping: left, by: key)
        let rightByKey = Dictionary(grouping: right, by: key)

        var pairByKey: [K: ComparisonPair] = [:]
        for (k, lefts) in leftByKey {
            guard lefts.count == 1, let rights = rightByKey[k], rights.count == 1 else { continue }
            pairByKey[k] = ComparisonPair(name: lefts[0].name, left: lefts[0], right: rights[0])
        }

        return (
            pairs: Array(pairByKey.values),
            unpairedLeft: left.filter { pairByKey[key($0)] == nil },
            unpairedRight: right.filter { pairByKey[key($0)] == nil }
        )
    }

    private static func ordering(_ lhs: ComparisonPair, _ rhs: ComparisonPair) -> Bool {
        let lhsNFC = lhs.name.precomposedStringWithCanonicalMapping
        let rhsNFC = rhs.name.precomposedStringWithCanonicalMapping
        if lhsNFC != rhsNFC { return lhsNFC < rhsNFC }
        return lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8)
    }
}
