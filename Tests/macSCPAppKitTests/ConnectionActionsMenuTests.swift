import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The toolbar menu that renders a backend's connection-level actions.
///
/// No test in this project draws a SwiftUI view; these are the decisions the
/// view reads, and the catalogue entries it looks its titles up in.
@Suite("Connection actions menu")
struct ConnectionActionsMenuTests {
    /// The four locales the app ships in; `en` is the source text.
    private static let locales = ["en", "de", "fr", "pl"]

    @MainActor @Test func aBackendWithNoActionsRendersNoCapsule() {
        let ssh = BackendDescriptor.descriptor(for: .ssh)
        let s3 = BackendDescriptor.descriptor(for: .s3)
        #expect(ConnectionActionsMenu.isPresented(for: ssh) == false)
        #expect(ConnectionActionsMenu.isPresented(for: s3) == true)
    }

    /// Presentation follows the descriptor's list for every backend, not for
    /// the two named above. Paired with a total so a table of empty lists
    /// cannot satisfy it.
    @MainActor @Test func presentationIsExactlyANonEmptyList() {
        var presented = 0
        for kind in ConnectionKind.allCases {
            let descriptor = BackendDescriptor.descriptor(for: kind)
            let expected = !descriptor.connectionActions.isEmpty
            #expect(ConnectionActionsMenu.isPresented(for: descriptor) == expected)
            if expected { presented += 1 }
        }
        #expect(presented > 0)
    }

    /// Every title key resolves in every shipped language: a key missing from
    /// one catalogue silently shows the English default there. The sentinel is
    /// absurd on purpose, so a hit can only be a real catalogue entry.
    @Test func everyActionTitleResolvesInAllFourLocales() {
        let sentinel = "ZZ-UNRESOLVED-ZZ"
        var checked = 0
        for kind in ConnectionKind.allCases {
            for action in BackendDescriptor.descriptor(for: kind).connectionActions {
                for locale in Self.locales {
                    let resolved = L10n.$localeOverride.withValue(locale) {
                        L10n.string(action.titleKey, sentinel)
                    }
                    checked += 1
                    #expect(resolved != sentinel)
                    #expect(!resolved.isEmpty)
                }
            }
        }
        #expect(checked > 0)
    }

    /// `titleDefault` is documented as the English source text, so the `en`
    /// catalogue must say exactly that. A second copy of a string that
    /// disagrees with the first is how the English UI drifts from its default.
    @Test func theEnglishCatalogueSaysTheDefault() {
        var checked = 0
        for kind in ConnectionKind.allCases {
            for action in BackendDescriptor.descriptor(for: kind).connectionActions {
                let english = L10n.$localeOverride.withValue("en") {
                    L10n.string(action.titleKey, "ZZ-UNRESOLVED-ZZ")
                }
                checked += 1
                #expect(english == action.titleDefault)
            }
        }
        #expect(checked > 0)
    }

    // MARK: - Wiring (source scans)

    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPAppKitTests/ConnectionActionsMenuTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Comments and string literals blanked, so the prose around the toolbar
    /// (which describes the menu in words) cannot satisfy or trip a scan.
    private static func code(_ relativePath: String) throws -> String {
        try SourceCorpus.code(of: repoRoot.appendingPathComponent(relativePath))
    }

    /// The toolbar's primary-action group: from its opening to the end of the
    /// file. Nil when the group is gone, which every caller turns into a
    /// failure rather than into an empty string that satisfies a scan.
    private static func toolbarGroup() throws -> String? {
        let source = try code("Sources/MacSCPAppKit/ContentView+Lifecycle.swift")
        guard let start = source.range(of: "ToolbarItemGroup(placement: .primaryAction)") else {
            return nil
        }
        return String(source[start.upperBound...])
    }

    /// Spec §5: the menu lands in the free area LEFT of the icon group, i.e.
    /// it is the first thing in the group. The upload button is the group's
    /// first icon; the menu must be constructed before it.
    @Test func theMenuIsTheFirstThingInThePrimaryActionGroup() throws {
        let group = try #require(try Self.toolbarGroup())
        let menu = try #require(group.range(of: "ConnectionActionsMenu("))
        let firstIcon = try #require(group.range(of: "uploadButton("))
        #expect(menu.lowerBound < firstIcon.lowerBound)
    }

    /// The window asks `isPresented(for:)` before it constructs the menu, so
    /// a backend with no actions gets no capsule rather than an empty one.
    /// The condition and the construction are both required to be there; the
    /// condition must come first.
    @Test func theMenuIsConstructedOnlyWhereItIsPresented() throws {
        let group = try #require(try Self.toolbarGroup())
        let condition = try #require(group.range(of: "ConnectionActionsMenu.isPresented(for:"))
        let construction = try #require(group.range(of: "ConnectionActionsMenu("))
        #expect(condition.lowerBound < construction.lowerBound)
    }

    /// The menu reads the descriptor's list and nothing about which backend it
    /// is: the design's rule is that the window never switches on
    /// `ConnectionKind` for this. The negative checks are paired with the
    /// positive one beside them -- the file must read `connectionActions` at
    /// all, or "mentions no kind" would be satisfied by an empty file.
    @Test func theMenuNamesNoBackendKind() throws {
        let menu = try Self.code("Sources/MacSCPAppKit/ConnectionActionsMenu.swift")
        #expect(menu.contains("connectionActions"))
        #expect(!menu.contains("ConnectionKind"))
        #expect(!menu.contains(".s3"))
        #expect(!menu.contains(".ssh"))
        #expect(!menu.contains(".webdav"))
    }
}
