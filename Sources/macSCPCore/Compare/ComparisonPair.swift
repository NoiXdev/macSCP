import Foundation

/// One relative name seen on one or both sides of a comparison.
///
/// `name` is the name as it will be SHOWN, taken from the left side when it
/// exists and from the right otherwise — the pairing key is a normalized
/// form, which is not what a person should read.
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
    /// Pairs two listings by name.
    ///
    /// The key is `precomposedStringWithCanonicalMapping` — NFC — because a
    /// local listing on macOS hands back NFD and a server usually stored
    /// NFC, and the same file must not appear as two rows. Case is NOT
    /// folded: two remote names differing only in case are two files on a
    /// case-sensitive server, and folding them here would drop one from the
    /// comparison entirely.
    public static func pairs(
        left: [RemoteFileItem], right: [RemoteFileItem]
    ) -> [ComparisonPair] {
        var byKey: [String: (left: RemoteFileItem?, right: RemoteFileItem?)] = [:]
        var order: [String] = []

        for item in left {
            let key = item.name.precomposedStringWithCanonicalMapping
            if byKey[key] == nil { byKey[key] = (nil, nil); order.append(key) }
            byKey[key]?.left = item
        }
        for item in right {
            let key = item.name.precomposedStringWithCanonicalMapping
            if byKey[key] == nil { byKey[key] = (nil, nil); order.append(key) }
            byKey[key]?.right = item
        }

        return order.sorted().compactMap { key in
            guard let sides = byKey[key] else { return nil }
            let name = sides.left?.name ?? sides.right?.name ?? key
            return ComparisonPair(name: name, left: sides.left, right: sides.right)
        }
    }
}
