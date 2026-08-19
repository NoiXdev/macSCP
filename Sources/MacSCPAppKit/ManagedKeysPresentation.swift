import Foundation
import macSCPCore

/// The outcome of reading `managed_keys.json`, in the two shapes the UI has
/// to tell apart: a list (possibly empty) or a store that could not be read.
/// Same shape and the same reason as `SnippetsLoad` — see its doc for why
/// collapsing both into `[]` is a defect rather than a simplification.
///
/// `ManagedKeyStore.all()` throws for a file it cannot decode. The SSH keys
/// sheet used to collapse that into `[]` and say "No keys yet. Generate one
/// to get started." over a file that still holds every key the user owns.
/// Nothing is lost in that state — `add` and `remove` read the file first
/// and throw too, so no write lands on top of it — but the user got no
/// signal at all, on the one screen whose job is to answer "which keys do I
/// have?".
enum ManagedKeysLoad: Equatable {
    case loaded([ManagedKey])
    case unreadable

    /// Reads `store` once. Anything `all()` throws lands in `.unreadable` —
    /// the error itself is not carried, because the sheet does not show it:
    /// a decoder's `debugDescription` is not a user-facing sentence.
    init(reading store: ManagedKeyStore) {
        if let keys = try? store.all() {
            self = .loaded(keys)
        } else {
            self = .unreadable
        }
    }

    /// The keys to list — empty for `.unreadable`, so a caller that only
    /// enumerates needs no special case. A caller that would otherwise CLAIM
    /// the store is empty must check `isUnreadable` instead.
    var keys: [ManagedKey] {
        switch self {
        case .loaded(let keys): return keys
        case .unreadable: return []
        }
    }

    var isUnreadable: Bool { self == .unreadable }

    /// Managed keys offerable to fill `keyPath` from (M17/T5): ed25519 only,
    /// because `SSHPrivateKeyLoader` can load nothing else, and only those
    /// whose stored `fileName` addresses a file inside the key directory —
    /// a key without a usable path has nothing to offer.
    ///
    /// This is an ENUMERATION, not a claim: a picker showing no keys says
    /// "nothing to offer here", not "you own no keys". The screen that makes
    /// the latter claim is `SSHKeysSheet`, one "Manage keys…" click away,
    /// and that one asks `isUnreadable`. Hence an unreadable store yields an
    /// empty list here rather than a notice row — which would otherwise mean
    /// threading a "disabled" flag through Core's field vocabulary for the
    /// generic renderer's sake.
    static func connectableKeys(
        in store: ManagedKeyStore = ManagedKeyStore(directory: SessionStore.defaultDirectory)
    ) -> [ManagedKey] {
        ManagedKeysLoad(reading: store).keys
            .filter { $0.type.isConnectable && store.privateKeyURL(for: $0) != nil }
    }
}
