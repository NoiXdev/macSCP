import Foundation
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The one resolver that turns the two ids `StoredSession` carries — a
/// group and a login set — into the names `SessionOverviewModel` renders.
///
/// It exists because Core's model takes NAMES, deliberately: a rendered
/// UUID is worse than an omitted row (Task 1's report, "No group name and no
/// login-set name in the facts"). The lookup itself is one function in the
/// App, so the two ids cannot be resolved differently at two call sites.
///
/// Every fixture below holds TWO candidates, and the assertion is that the
/// one the id names comes back. A single-candidate fixture would be
/// satisfied by a resolver that returns `first` and ignores the id, which is
/// the mistake worth catching here.
@Suite("Session overview name resolution")
struct SessionOverviewNamesTests {
    private static func group(_ name: String) -> StoredGroup {
        StoredGroup(name: name)
    }

    private static func loginSet(_ name: String) -> LoginSet {
        LoginSet(name: name, username: "someone")
    }

    private static func session(groupID: UUID?, loginSetID: UUID?) -> StoredSession {
        StoredSession(
            name: "Overview fixture", groupID: groupID, loginSetID: loginSetID, kind: .ssh,
            ssh: StoredSSHConfig(host: "example.test", username: "someone"))
    }

    @Test func theGroupNameComesFromTheIdAndNotFromTheOrder() {
        let first = Self.group("Alpha")
        let wanted = Self.group("Bravo")
        let names = SessionOverviewNames.resolve(
            for: Self.session(groupID: wanted.id, loginSetID: nil),
            groups: [first, wanted], loginSets: [])
        #expect(names.group == "Bravo")
        #expect(names.loginSet == nil)
    }

    @Test func theLoginSetNameComesFromTheIdAndNotFromTheOrder() {
        let first = Self.loginSet("Work laptop")
        let wanted = Self.loginSet("Backup account")
        let names = SessionOverviewNames.resolve(
            for: Self.session(groupID: nil, loginSetID: wanted.id),
            groups: [], loginSets: [first, wanted])
        #expect(names.loginSet == "Backup account")
        #expect(names.group == nil)
    }

    /// An id that names nothing resolves to `nil`, not to a UUID and not to
    /// whatever happens to be first. The overview omits the row entirely for
    /// `nil` (`SessionOverviewModel.loginSetFact`), which is the right
    /// answer for a group that was deleted out from under the session.
    @Test func anIdThatNamesNothingResolvesToNothing() {
        let names = SessionOverviewNames.resolve(
            for: Self.session(groupID: UUID(), loginSetID: UUID()),
            groups: [Self.group("Alpha")], loginSets: [Self.loginSet("Work laptop")])
        #expect(names.group == nil)
        #expect(names.loginSet == nil)
    }
}
