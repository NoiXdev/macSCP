import Foundation
import Testing
@testable import macSCPCore

/// M31: an unsaved connection has no `StoredSession` and therefore had no
/// session id to log against, so it logged nothing at all -- including the
/// M21 plaintext-transport note. These pin the one decision that fixes
/// that: which id a connect writes its audit trail under.
@Suite("Ad-hoc audit")
struct AdHocAuditTests {
    /// Both directions, so neither a hardcoded stored id nor a hardcoded
    /// ad-hoc id satisfies the pair.
    @Test func aStoredSessionLogsUnderItsOwnID() {
        let stored = UUID()
        #expect(AdHocAudit.logSessionID(storedID: stored) == stored)
    }

    @Test func anUnsavedConnectionLogsUnderTheAdHocID() {
        #expect(AdHocAudit.logSessionID(storedID: nil) == AdHocAudit.sessionID)
    }

    /// The id must be the SAME across calls -- a freshly generated one per
    /// connect would scatter the ad-hoc trail across logs no screen can
    /// reach, which is the very gap this milestone closes.
    @Test func theAdHocIDIsStableAcrossCalls() {
        #expect(AdHocAudit.logSessionID(storedID: nil)
                == AdHocAudit.logSessionID(storedID: nil))
    }
}
