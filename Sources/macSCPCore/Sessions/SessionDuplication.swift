import Foundation

/// What a duplicated session carries — a value, not a menu action.
///
/// The rule is one sentence: **the copy inherits every reference and no
/// secret.** Group, tags, login-set binding, protocol block and jump
/// specification all name something that exists elsewhere and stays where it
/// is, so they travel. A secret is the opposite: copying one would put a
/// second Keychain entry into the user's keychain that they never asked for
/// and would have to know about the next time they change or revoke the
/// first — and nobody ever knows about the second.
///
/// The asymmetry that follows is the rule at work rather than a gap in it: a
/// session bound to a login set is complete the moment it is copied, because
/// its credential hangs on the SET; a session that owns its password asks
/// once on the copy's first connect.
///
/// This lives beside `SessionNameCollision` and `SidebarOrdering` for their
/// reason: everything it decides depends only on the template and the names
/// already in use, so it can be decided in full by a test, and the sidebar is
/// left with nothing to derive.
///
/// ## The two Keychain slots
///
/// A session addresses its secret by its own `id` — the slot IS the
/// identifier — so a fresh `id` is already an empty slot, and pointing a copy
/// at the template's secret is not even expressible without copying it.
///
/// A jump carries a SECOND one. `JumpSpec.secretID` is a different slot from
/// the session's `id`, so a fresh `id` says nothing about it: a spec taken
/// over field for field would leave the copy reading the template's manual
/// jump secret, in the one place a reader of this file would not look.
/// `SessionImportPlanner.makePlanned` answers the same question the same way
/// for an imported session, and for the same reason.
public enum SessionDuplication {
    /// A copy of `template` under a free name, with every reference carried
    /// and every Keychain slot fresh.
    ///
    /// `existing` is the sessions the name must avoid, and it is expected to
    /// CONTAIN the template — the copy of "web" is "web 2", not a second
    /// "web" that `SessionListViewModel.save`'s upsert-by-name would later
    /// merge back into the first.
    ///
    /// The name comes from `SessionNameCollision.freeName(basedOn:avoiding:)`
    /// and from nowhere else. That function already compares names the way
    /// `save` does, and a second arithmetic beside it would be free to
    /// disagree with saving about what "taken" means.
    ///
    /// `position` travels too, so the copy ranks where the template ranks:
    /// under `SidebarOrdering`'s equal-rank rule that puts it beside the row
    /// it was made from rather than at some unrelated place in the folder.
    public static func copy(
        of template: StoredSession, avoiding existing: [StoredSession]
    ) -> StoredSession {
        var copy = StoredSession(
            id: UUID(),
            name: SessionNameCollision.freeName(basedOn: template.name, avoiding: existing),
            groupID: template.groupID,
            loginSetID: template.loginSetID,
            kind: template.kind,
            ssh: template.ssh,
            s3: template.s3,
            webdav: template.webdav,
            paneVisibility: template.paneVisibility,
            tags: template.tags,
            position: template.position)
        // `importSource`/`importID`/`importedAt` (M24) are deliberately NOT
        // taken over here: they stay at `StoredSession.init`'s own default
        // (`nil`), because the copy did not come from Cyberduck — the
        // template's import history is not something a manual "Duplicate"
        // should hand to a second record.
        // The one field that is taken over and then thrown away. Everything
        // else about the jump — host, port, username, auth kind, key path,
        // and the `loginSetID`/`sessionID` references — is carried by the
        // assignment above, which is what makes a field added to `JumpSpec`
        // later travel by default. A field added as a second SECRET slot
        // would travel by default too, and that is what
        // `SessionDuplicationTests.everyIdentifierAJumpCarriesIsAccountedFor`
        // is there to refuse silently passing.
        copy.ssh?.jump?.secretID = UUID()
        return copy
    }
}
