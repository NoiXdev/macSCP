import Foundation
import Testing
@testable import macSCPCore

/// What a duplicated session carries, and — the half that has to be checked
/// harder — what it does not.
///
/// The design's rule is one sentence: a copy inherits every REFERENCE and no
/// SECRET. References are cheap to assert and cheap to see when they break.
/// The secret half is the one that can be bypassed without anything looking
/// wrong, because a Keychain slot is a bare `UUID` and a copy that carried
/// one forward would read exactly like a copy that generated one.
///
/// There are two such slots, not one: the session's own `id` IS its slot,
/// and a jump carries a second, `JumpSpec.secretID`. The second is the one
/// nobody looks at, so it gets its own test and its own reflective guard
/// below.
@Suite("Session duplication")
struct SessionDuplicationTests {
    private func jump(
        loginSetID: UUID? = nil, sessionID: UUID? = nil, secretID: UUID = UUID()
    ) -> StoredSession.JumpSpec {
        StoredSession.JumpSpec(
            host: "bastion.example.com", port: 2022, username: "hop",
            authKind: .privateKey, keyPath: "/keys/hop",
            loginSetID: loginSetID, secretID: secretID, sessionID: sessionID)
    }

    // MARK: - Fresh: the two slots

    @Test func theCopyGetsItsOwnIdAndThereforeItsOwnEmptySecretSlot() {
        let template = sshSession(name: "web")
        let copy = SessionDuplication.copy(of: template, avoiding: [template])
        #expect(copy.id != template.id)
    }

    /// The one a raw field copy would get wrong in silence: `secretID` is a
    /// DIFFERENT slot from the session's `id`, so a fresh `id` says nothing
    /// about it.
    @Test func theJumpsOwnSecretSlotIsFreshToo() {
        let spec = jump()
        let template = sshSession(name: "web", jump: spec)
        let copy = SessionDuplication.copy(of: template, avoiding: [template])
        #expect(copy.jump?.secretID != spec.secretID)
    }

    // MARK: - Carried: everything that is a reference

    @Test func theNameComesFromTheExistingRule() {
        let template = sshSession(name: "web")
        let copy = SessionDuplication.copy(of: template, avoiding: [template])
        #expect(copy.name == SessionNameCollision.freeName(
            basedOn: "web", avoiding: [template]))
    }

    @Test func theCopyLandsInTheTemplatesGroup() {
        let group = UUID()
        let template = sshSession(name: "web", groupID: group)
        let copy = SessionDuplication.copy(of: template, avoiding: [template])
        #expect(copy.groupID == group)
    }

    @Test func theLoginSetBindingTravels() {
        let set = UUID()
        let template = sshSession(name: "web", loginSetID: set)
        let copy = SessionDuplication.copy(of: template, avoiding: [template])
        #expect(copy.loginSetID == set)
    }

    @Test func theTagsTravel() {
        var template = sshSession(name: "web")
        template.tags = ["docker", "prod"]
        let copy = SessionDuplication.copy(of: template, avoiding: [template])
        #expect(copy.tags == ["docker", "prod"])
    }

    @Test func theProtocolAndItsConnectionFieldsTravel() {
        let template = sshSession(
            name: "web", host: "h.example.com", port: 2201, username: "tim",
            authKind: .privateKey, keyPath: "/keys/id_ed25519")
        let copy = SessionDuplication.copy(of: template, avoiding: [template])
        #expect(copy.kind == .ssh)
        #expect(copy.ssh?.host == "h.example.com")
        #expect(copy.ssh?.port == 2201)
        #expect(copy.ssh?.username == "tim")
        #expect(copy.ssh?.authKind == .privateKey)
        #expect(copy.ssh?.keyPath == "/keys/id_ed25519")
    }

    @Test func anS3SessionCarriesItsOwnBlock() {
        let template = s3Session(name: "bucket")
        let copy = SessionDuplication.copy(of: template, avoiding: [template])
        #expect(copy.kind == .s3)
        #expect(copy.s3 == template.s3)
        #expect(copy.ssh == nil)
    }

    @Test func aWebDAVSessionCarriesItsOwnBlock() {
        let template = webdavSession(name: "cloud")
        let copy = SessionDuplication.copy(of: template, avoiding: [template])
        #expect(copy.kind == .webdav)
        #expect(copy.webdav == template.webdav)
    }

    @Test func thePaneLayoutAndTheRankTravel() {
        var template = sshSession(name: "web")
        template.paneVisibility = .bothVisible
        template.position = 7
        let copy = SessionDuplication.copy(of: template, avoiding: [template])
        #expect(copy.paneVisibility == .bothVisible)
        #expect(copy.position == 7)
    }

    @Test func theJumpsConnectionFieldsTravel() {
        let template = sshSession(name: "web", jump: jump())
        let copy = SessionDuplication.copy(of: template, avoiding: [template])
        #expect(copy.jump?.host == "bastion.example.com")
        #expect(copy.jump?.port == 2022)
        #expect(copy.jump?.username == "hop")
        #expect(copy.jump?.authKind == .privateKey)
        #expect(copy.jump?.keyPath == "/keys/hop")
    }

    /// A jump's `loginSetID` and `sessionID` name something that exists
    /// elsewhere and stays where it is — the opposite case from `secretID`,
    /// and the reason the rule is "no secret" rather than "no UUID".
    @Test func theJumpsReferencesTravel() {
        let set = UUID()
        let referenced = UUID()
        let template = sshSession(
            name: "web", jump: jump(loginSetID: set, sessionID: referenced))
        let copy = SessionDuplication.copy(of: template, avoiding: [template])
        #expect(copy.jump?.loginSetID == set)
        #expect(copy.jump?.sessionID == referenced)
    }

    @Test func aSessionWithoutAJumpGetsNoneEither() {
        let template = sshSession(name: "web")
        let copy = SessionDuplication.copy(of: template, avoiding: [template])
        #expect(copy.jump == nil)
    }

    // MARK: - The guard over the slot that has no name of its own

    /// Every `UUID`-shaped field a jump carries, named with what the copy
    /// must do with it. This is the positive check beside the fresh-slot
    /// test above: that test asserts one field is regenerated, and would go
    /// on passing over a `JumpSpec` that had grown a SECOND secret slot the
    /// copy carried forward raw.
    ///
    /// The three names are counted here, in the pass that writes them, off
    /// `JumpSpec`'s own declaration: `loginSetID` and `sessionID` are
    /// references and travel; `secretID` is a Keychain slot and is
    /// regenerated. A fourth one turns this red, and whoever adds it has to
    /// say which of the two it is.
    @Test func everyIdentifierAJumpCarriesIsAccountedFor() {
        let mirror = Mirror(reflecting: jump(loginSetID: UUID(), sessionID: UUID()))
        let identifierFields = mirror.children.compactMap { child -> String? in
            let type = String(describing: type(of: child.value))
            guard type == "UUID" || type == "Optional<UUID>" else { return nil }
            return child.label
        }
        #expect(Set(identifierFields) == ["secretID", "loginSetID", "sessionID"], """
            `JumpSpec` carries an identifier this rule has not been told about. Decide \
            which it is: a REFERENCE to something that stays where it is (it travels with \
            the copy, like `loginSetID` and `sessionID`), or a KEYCHAIN SLOT (the copy \
            gets a fresh one, like `secretID`) — then add it here and to \
            `SessionDuplication.copy(of:avoiding:)`.
            """)
    }
}
