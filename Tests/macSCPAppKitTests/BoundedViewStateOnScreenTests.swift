import AppKit
import Foundation
import SwiftUI
import Testing

@testable import MacSCPAppKit

/// Holds the registry states that exist FOR a section to be on screen to
/// that section actually being on screen.
///
/// `entriesOfOneTypeMeasureDifferentStates` tells two entries of one type
/// apart by what they measure, so a state that merely renders one more line
/// than its neighbour passes it. The jump-host entry and the open-declaration
/// entry were admitted that way, and for a stretch measured nothing the
/// neighbours did not (identical minimums in every catalogue). These tests
/// pin the claim directly: the control only that section carries is found in
/// the hosted view.
///
/// **How "on screen" is read.** The entry is hosted in a window and the AppKit
/// view tree is walked for the controls SwiftUI backs with real views: text
/// fields (by placeholder) and segmented controls (by their segment labels).
/// Plain `Text` is drawn, not a view, so it cannot be found this way; the
/// accessibility tree is empty in a test process (measured 2026-10-18: every
/// label list came back `[]`).
///
/// The positive beside each negative: the neighbouring state is read the same
/// way and must NOT show the control, so a walk that found nothing, or
/// everything, fails here instead of passing.
@Suite("Registry states are on screen", .serialized)
@MainActor
struct BoundedViewStateOnScreenTests {
    /// Placeholders of every text field in the hosted entry, in `locale`.
    private static func placeholders(of entry: BoundedViewEntry, locale: String) -> [String] {
        L10n.$localeOverride.withValue(locale) {
            SheetBound.$isSuspendedForMeasurement.withValue(true) {
                let host = NSHostingView(rootView: entry.content())
                host.frame = CGRect(x: 0, y: 0, width: 900, height: 900)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                var found: [String] = []
                @MainActor func walk(_ view: NSView) {
                    if let field = view as? NSTextField, let placeholder = field.placeholderString {
                        found.append(placeholder)
                    }
                    for child in view.subviews { walk(child) }
                }
                walk(host)
                return found
            }
        }
    }

    private static func entry(_ stateName: String) throws -> BoundedViewEntry {
        let matches = BoundedViewRegistry.all.filter { $0.stateName == stateName }
        #expect(matches.count == 1, "\(stateName): \(matches.count) entries")
        return try #require(matches.first)
    }

    /// The jump host's own field carries a placeholder only that block has.
    /// The plain connection entry is the control: same view, jump off.
    @Test func theJumpHostEntryShowsTheJumpHostBlock() throws {
        let jump = try Self.entry(BoundedViewRegistry.jumpHostState)
        let plain = try #require(
            BoundedViewRegistry.all.first {
                $0.typeName == jump.typeName && $0.stateName != jump.stateName
            })
        for locale in LayoutMeasure.shippedLocales {
            let hostPlaceholder = L10n.$localeOverride.withValue(locale) {
                L10n.string("form.jump.host.placeholder", "bastion.example.com")
            }
            #expect(
                Self.placeholders(of: jump, locale: locale).contains(hostPlaceholder),
                "\(locale): the jump entry does not show the jump host field")
            #expect(
                !Self.placeholders(of: plain, locale: locale).contains(hostPlaceholder),
                "\(locale): the plain entry shows the jump host field, so the walk proves nothing")
        }
    }

    /// Two declarations sharing a name are faulty, a faulty card is drawn
    /// open, and an open card carries a name field. The collapsed stored
    /// snippet is the control: its declarations are one-line summaries.
    @Test func theOpenDeclarationEntryShowsBothCardsOpen() throws {
        let open = try Self.entry(BoundedViewRegistry.openDeclarationsState)
        let collapsed = try Self.entry(BoundedViewRegistry.collapsedDeclarationsState)
        for locale in LayoutMeasure.shippedLocales {
            let namePlaceholder = L10n.$localeOverride.withValue(locale) {
                L10n.string("snippets.variables.name", "Name")
            }
            let openCount = Self.placeholders(of: open, locale: locale)
                .filter { $0 == namePlaceholder }.count
            let collapsedCount = Self.placeholders(of: collapsed, locale: locale)
                .filter { $0 == namePlaceholder }.count
            #expect(openCount == 2, "\(locale): \(openCount) open declaration cards, expected 2")
            #expect(
                collapsedCount == 0,
                "\(locale): the collapsed entry shows \(collapsedCount) name fields, so the walk proves nothing")
        }
    }
}
