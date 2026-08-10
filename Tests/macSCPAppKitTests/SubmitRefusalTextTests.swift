import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("SubmitRefusalText")
struct SubmitRefusalTextTests {
    /// Every refusal case, listed by hand. A new case added to
    /// `SubmitRefusal` without a line here is caught by the exhaustive
    /// switch below, which fails to compile until it is handled.
    static let allCases: [SubmitRefusal] = [
        .targetSetMissing, .targetSetKindMismatch,
        .jumpSetMissing, .jumpSetNotSSH,
        .jumpSessionMissing, .jumpChainNotSupported,
        .jumpSessionNotSSH, .jumpSessionLoginUnresolvable,
    ]

    /// `.targetSetMissing`, `.jumpSetMissing`, and
    /// `.jumpSessionLoginUnresolvable` intentionally share the
    /// `loginSets.missingSet` text — see `SubmitRefusalText`'s doc comment
    /// on `.jumpSessionLoginUnresolvable`. This is the one collision the
    /// mapping is allowed to have; every other pair below must be distinct.
    /// `SubmitRefusal` is `Equatable` but not `Hashable`, so this is an
    /// array rather than a `Set` — membership is checked with `contains`.
    static let documentedCollision: [SubmitRefusal] = [
        .targetSetMissing, .jumpSetMissing, .jumpSessionLoginUnresolvable,
    ]

    /// A refusal the user cannot read is a refusal that looks like a
    /// silent failure — the submit simply does nothing and no text appears.
    @Test func everyRefusalHasText() {
        for refusal in Self.allCases {
            let isEmpty = SubmitRefusalText.message(for: refusal).isEmpty
            #expect(isEmpty == false, "\(refusal) has no message")
        }
    }

    /// Two refusals that read identically send the user to fix the wrong
    /// thing. This is what a copy-paste slip in the mapping looks like —
    /// except for `documentedCollision` above, which is deliberate reuse of
    /// one catch-all message, not a slip.
    @Test func noUndocumentedRefusalsReadTheSame() {
        var seen: [String: SubmitRefusal] = [:]
        for refusal in Self.allCases {
            let text = SubmitRefusalText.message(for: refusal)
            if let existing = seen[text] {
                let isDocumented =
                    Self.documentedCollision.contains(refusal)
                    && Self.documentedCollision.contains(existing)
                #expect(
                    isDocumented,
                    "\(refusal) reads the same as \(existing), and neither is in documentedCollision")
            }
            seen[text] = refusal
        }
    }

    /// The list above is hand-maintained; this switch makes the compiler
    /// reject a new `SubmitRefusal` case that nobody added to it.
    @Test func theCaseListIsComplete() {
        for refusal in Self.allCases {
            switch refusal {
            case .targetSetMissing, .targetSetKindMismatch,
                .jumpSetMissing, .jumpSetNotSSH,
                .jumpSessionMissing, .jumpChainNotSupported,
                .jumpSessionNotSSH, .jumpSessionLoginUnresolvable:
                continue
            }
        }
        #expect(Self.allCases.count == 8)
    }
}
