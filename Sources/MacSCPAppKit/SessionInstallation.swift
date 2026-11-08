import Foundation
import Observation
import macSCPCore

/// A tab's session slot, and the asking that comes with filling it.
///
/// **A type in a file of its own, and that is the whole mechanism.** The
/// property it holds is `private(set)`, so the only code that can put a
/// `BrowserSession` anywhere is the code in this file, and the only entry
/// point this file offers for putting one there is `install(_:over:kind:)`,
/// whose body also starts the probe that asks the connection whether it will
/// take a permission change (Ruling T7.1 of the FTP plan). Installing a
/// session and asking its connection are therefore one operation that no
/// caller can take half of — not because a scan says so, but because the
/// other half does not compile.
///
/// Why it is not a `private(set)` on `SessionTab` itself, which is where
/// Ruling T8.8 first pointed: `private` in Swift is FILE-scoped, and the
/// plant this exists to refuse was written inside `SessionTab.swift` — a
/// one-line `installQuietly(_:)` that assigns the session and asks nothing,
/// with the sanctioned `installSession(…)` call left in place but made
/// unreachable. A `private(set)` therefore would NOT have refused it.
///
/// That span is a language fact and it was measured rather than recalled,
/// 2026-11-08, with two throwaway files under `Sources/MacSCPAppKit` that
/// were built and then removed with `rm`:
///
///     @MainActor final class ZZPrivateSetSpanProbe {
///         private(set) var slot: Int = 0
///         func quietlyFromTheSameFile(_ value: Int) { slot = value }
///     }
///
/// `swift build` exits **0** with that file alone — `grep -c 'error:'` on
/// the log prints 0. Adding a second file whose only statement is
/// `probe.slot = value` exits **1** with
/// `ZZPrivateSetSpanProbeOther.swift:4:15: error: cannot assign to property:
/// 'slot' setter is inaccessible`. One file away, refused; same file,
/// accepted. The quiet-install plant lives in the same file as the property,
/// which is the half `private(set)` cannot see.
///
/// With the storage here instead, that plant does not compile either, and the
/// diagnostics are quoted in the fix-round-2 commit that moved it: a write in
/// `SessionTab.swift` or `ContentView.swift` is `cannot assign to property:
/// 'session' is a get-only property`, and a write straight at this type's
/// property is `'session' setter is inaccessible`.
///
/// **What the compiler does not close, and what now stands in its place.**
/// Swift's narrowest access scope is a file, so a function added to THIS
/// file can still write the property. That residual was not a limit to
/// record, it was a hole: the re-review of fix round 2 planted
/// `func zzInstallQuietly(_ built: BrowserSession) { session = built }` here,
/// called it with the sanctioned `tab.installSession(…)` left present and
/// byte-identical inside a never-taken `if`, and the plant was **GREEN
/// against 162 tests**. The argument that this file "has no other reason to
/// grow" was the same shape as the `change(_:)` argument below, which a
/// plant also falsified.
///
/// So the declared surface of this type is pinned by a POSITIVE check:
/// `ReconnectWiringGuardTests.sessionInstallationDeclaresExactlyTheSurfaceSanctionedHere`
/// asserts that the set of lines at this class's own brace depth is exactly
/// the sanctioned set. It names nothing about a violation — a fourth anchor
/// is what bought three GREEN plants on this property — so there is no
/// spelling to evade, and it requires something PRESENT, so it cannot go
/// stale in silence. **Adding a member here is red, and so is removing
/// one.** The cost is one entry in that list per declaration line, which is
/// the cost the "per-field writes" comment below already accepts for a new
/// field.
@MainActor
@Observable
final class SessionInstallation {
    /// The installed session, or `nil` while this tab is not connected.
    ///
    /// `private(set)`, which here means "written in this file only" — see the
    /// type's own doc comment for why the file boundary is the mechanism.
    private(set) var session: BrowserSession?

    /// The task asking this tab's connection whether it will take a
    /// permission change. Kept so a test can await it, so a second install
    /// can cancel the first, and so `TabTeardown.run(_:reason:)` can cancel
    /// it when the tab's connection goes away; not observable state.
    @ObservationIgnored private(set) var permissionProbe: Task<Void, Never>?

    /// Installs `built` and asks its connection about permission editing.
    ///
    /// The probe is started, not awaited: a server that answers `SITE HELP`
    /// slowly must not hold the browser back, and until the answer lands the
    /// editor is offered as it always was. The answer is written only to the
    /// session it was asked about (`recordPermissionEditing`), which is what
    /// makes a late first answer harmless to a second session.
    func install(
        _ built: BrowserSession, over fileSystem: any RemoteFileSystem, kind: ConnectionKind
    ) {
        permissionProbe?.cancel()
        session = built
        let sessionID = built.id
        permissionProbe = Task { [weak self] in
            await self?.recordPermissionEditing(
                of: fileSystem, kind: kind, forSession: sessionID)
        }
    }

    /// Asks the connection whether it will take a permission change, and
    /// records the answer on the session it was asked for.
    ///
    /// The question is `PermissionsAvailability.isOffered(for:on:)`: the
    /// capability first, then the connection's own probe where it has one --
    /// for FTP, whether the server has `SITE CHMOD`.
    ///
    /// **The write is refused unless the session is still the one that was
    /// asked about.** The probe may be a round trip, and a tab can be torn
    /// down and reconnected inside it; an answer about the old connection
    /// written onto the new one would hide, or offer, an editor on a server
    /// the question was never put to. `id` is compared, as
    /// `SessionTab.checksumLedgerBinding` compares it, for the same reason.
    func recordPermissionEditing(
        of fileSystem: any RemoteFileSystem, kind: ConnectionKind, forSession sessionID: UUID
    ) async {
        let offered = await PermissionsAvailability.isOffered(for: kind, on: fileSystem)
        guard session?.id == sessionID else { return }
        session?.permissionEditing = offered
    }

    /// Cancels the probe without releasing the session.
    ///
    /// `TabTeardown.run(_:reason:)` calls this beside the three other
    /// activities of the same shape it cancels, and BEFORE the stage that
    /// closes the connection — which is the whole point of its position
    /// there. A probe left running reaches `FTPConnectionPool.command()`
    /// after that stage, finds no command connection because `shutdown()`
    /// nils it, and dials: a full connect, greeting, TLS where the mode has
    /// it, and a login with the password the pool still holds. The answer is
    /// then dropped by `recordPermissionEditing`'s session guard, so the only
    /// thing such a connection achieves is existing, and nothing closes it —
    /// this project has no `deinit` cleanup, by invariant. Measured against a
    /// loopback server by the re-review of fix round 1: control connections
    /// 1 -> 2, and two `USER` commands after `disconnect()`.
    ///
    /// Synchronous: it raises the task's cancellation and waits for nothing,
    /// like the three cancels it stands with.
    func cancelPermissionProbe() {
        permissionProbe?.cancel()
    }

    /// Releases the session, and the probe with it.
    ///
    /// The named clear path `TabTeardown.run(_:reason:)` uses in place of the
    /// `tab.session = nil` it used to write. A separate entry point rather
    /// than an exemption on the installer: releasing a session and installing
    /// one are different operations, and only one of them owes the
    /// connection a question.
    func clear() {
        permissionProbe?.cancel()
        session = nil
    }

    // MARK: - The per-field writes

    /// One named method per per-session field that is written AFTER the
    /// install, and NO general-purpose mutator, which is the part that was
    /// measured rather than reasoned.
    ///
    /// `BrowserSession` is a struct, so `session?.field = value` from outside
    /// this file needs the setter this type does not expose; something has to
    /// stand in for it. The first draft of that something was
    /// `change(_ body: (inout BrowserSession) -> Void)`, and it reopened
    /// exactly the hole this type exists to close: `inout BrowserSession`
    /// also accepts `$0 = built`, so `installQuietly(_:)` could be written
    /// as `changeSession { $0 = built }`. Planted through
    /// `scripts/mutation-probe` in the foreground against
    /// `PermissionsAvailabilityTests|PermissionsSurfaceGuardTests|ObjectLockSheetTests|PermissionEditingRecordTests|ReconnectWiringGuardTests`
    /// (control: `161 test(s) ran, 0 pre-existing failures` — the figure that
    /// run printed, and a figure about that run only: the same filter counted
    /// 162 by the end of fix round 2 and 163 once fix round 3 added
    /// `sessionInstallationDeclaresExactlyTheSurfaceSanctionedHere` to a suite
    /// inside it), with the
    /// sanctioned `tab.installSession(…)` call left present but unreachable:
    /// **GREEN**. The argument written in its place — that with nothing
    /// installed the call is a no-op, so "every assertion about a connected
    /// tab fails" — was a prediction, and the run falsified it.
    ///
    /// A field setter cannot install: it takes the field's own type, so
    /// there is no spelling of it that carries a whole session. The cost is
    /// that a new per-session field written after the install needs a line
    /// here, and that is the intended cost — it is one line in the file a
    /// reviewer reads for exactly this question.
    func setShowsFiles(_ value: Bool) {
        session?.showsFiles = value
    }

    func setChecksums(_ ledger: ChecksumLedger, for side: BrowserPaneSide) {
        switch side {
        case .local: session?.localChecksums = ledger
        case .remote: session?.remoteChecksums = ledger
        }
    }

    func setObjectLockStates(_ cache: ObjectLockStateCache?) {
        session?.objectLockStates = cache
    }

    func setBucketVersioning(_ cache: BucketVersioningCache?) {
        session?.bucketVersioning = cache
    }
}
