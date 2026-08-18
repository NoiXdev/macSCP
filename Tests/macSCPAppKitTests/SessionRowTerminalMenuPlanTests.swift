import Foundation
import Testing

@testable import MacSCPAppKit
import macSCPCore

/// Pins `SessionRowTerminalMenuPlan.build`, the rule behind a session row's
/// "Open Terminal" and "Open in External Terminal" entries (P3c/T2).
///
/// The rule is here rather than in `SessionRow`'s context menu for the
/// reason this project has twice paid for: a visibility decision inside a
/// SwiftUI body is a decision no test can reach. This suite proves WHICH
/// case each `ConnectionKind` maps to. It does NOT prove what the menu draws
/// for each — there is no rendering harness in this project, and the type's
/// own doc comment says so rather than implying otherwise.
@Suite("SessionRowTerminalMenuPlan")
struct SessionRowTerminalMenuPlanTests {
    /// The two entries exist because SSH has a shell.
    @Test func sshOffersBothEntries() {
        #expect(SessionRowTerminalMenuPlan.build(for: .ssh) == .shown)
    }

    /// The case the "hidden, not greyed" ruling is about: a bucket has no
    /// shell, and a permanently dead entry on it would explain nothing.
    @Test func aBackendWithoutAShellHidesThem() {
        #expect(SessionRowTerminalMenuPlan.build(for: .s3) == .hidden)
        #expect(SessionRowTerminalMenuPlan.build(for: .webdav) == .hidden)
    }

    /// The rule is the backend's declared capability, not a list of kinds
    /// kept in step by hand: every kind must land on the case its own
    /// `supportsShell` says, so a fourth backend is decided by its
    /// descriptor alone and this suite covers it the day it is added.
    @Test(arguments: ConnectionKind.allCases)
    func everyKindFollowsItsOwnShellCapability(kind: ConnectionKind) {
        let supportsShell = BackendDescriptor.descriptor(for: kind).capabilities.supportsShell
        #expect(SessionRowTerminalMenuPlan.build(for: kind).isShown == supportsShell)
    }

    /// Both cases are actually reachable across the kinds that exist — the
    /// check above would also pass for a `build` that answered a constant
    /// if every backend happened to agree, and this is what rules that out.
    @Test func bothOutcomesOccurAcrossTheExistingBackends() {
        let plans = ConnectionKind.allCases.map(SessionRowTerminalMenuPlan.build(for:))
        #expect(plans.contains(.shown))
        #expect(plans.contains(.hidden))
    }

    @Test func isShownIsTrueOnlyForTheShownCase() {
        #expect(SessionRowTerminalMenuPlan.shown.isShown)
        #expect(!SessionRowTerminalMenuPlan.hidden.isShown)
    }

    // MARK: - Catalog resolution

    /// The two new keys this task adds — a missing key renders as its own
    /// literal default in the menu rather than failing a build, so it needs
    /// a test to be noticed (same guard shape as
    /// `SessionRowSnippetMenuPlanTests.theSnippetSubmenuNoticesResolveFromTheCatalog`).
    @Test func theTerminalEntryTitlesResolveFromTheCatalog() {
        #expect(L10n.string("sidebar.openTerminal", "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ")
        #expect(
            L10n.string("sidebar.openExternalTerminal", "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ")
    }
}
