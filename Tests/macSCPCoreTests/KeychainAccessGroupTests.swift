import Foundation
import Testing
@testable import macSCPCore

/// `build(teamIdentifier:)` is the pure, deterministic half of
/// `KeychainAccessGroup` — it does not touch the Security framework, so it
/// is fully covered without any code-signing environment assumptions.
/// `current()` itself is covered separately below by a single assertion
/// that leans on a real, verified fact about this project's toolchain (see
/// that test's doc comment).
@Suite("KeychainAccessGroup")
struct KeychainAccessGroupTests {
    @Test func buildsTheGroupFromANonEmptyTeamIdentifier() {
        #expect(KeychainAccessGroup.build(teamIdentifier: "5V8ZCK434F") == "5V8ZCK434F.dev.noix.macscp")
    }

    @Test func trimsWhitespaceAroundTheTeamIdentifier() {
        #expect(KeychainAccessGroup.build(teamIdentifier: "  5V8ZCK434F  ") == "5V8ZCK434F.dev.noix.macscp")
    }

    @Test func anEmptyTeamIdentifierYieldsNoGroup() {
        #expect(KeychainAccessGroup.build(teamIdentifier: "") == nil)
    }

    @Test func aBlankTeamIdentifierYieldsNoGroup() {
        #expect(KeychainAccessGroup.build(teamIdentifier: "   ") == nil)
    }

    /// Proves the ad-hoc-dev-build case end to end, through the REAL
    /// Security-framework path, not just the pure builder above.
    ///
    /// This is safe to assert unconditionally (no `MACSCP_KEYCHAIN`-style
    /// gate) because of a fact about this toolchain verified independently
    /// before writing this test: `swift build`/`swift test` ad-hoc-sign
    /// every binary and test bundle they produce (confirmed via `codesign
    /// -dv` on both `.build/.../macSCPPackageTests.xctest` and the plain
    /// executables — both report `Signature=adhoc` and
    /// `TeamIdentifier=not set`). Ad-hoc signing by definition embeds no
    /// team identifier — `codesign --sign -` has no identity to pull one
    /// from — so THIS test binary, running THIS assertion, can never have a
    /// team identifier, in this environment or in CI (which has no
    /// Developer ID identity installed either). `current()` reading its own
    /// process's signature must therefore return `nil` here, exactly the
    /// "fall back to the plain, group-less keychain path" behavior the dev
    /// build has always had.
    @Test func currentYieldsNoGroupForThisAdHocSignedTestBinary() {
        #expect(KeychainAccessGroup.current() == nil)
    }
}
