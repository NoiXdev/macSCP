import SwiftUI
import macSCPCore

/// One release's header text, "<version> (<date>)" or just "<version>" when
/// the changelog carried no date for it (`ChangelogRelease.date` is `nil`
/// for a malformed heading — Task 1's parser is total, never rejecting).
/// A free function, not built inline inside a `Text(`, so the composed
/// string never sits behind a literal in this file (see
/// `WhatsNewWiringGuardTests`'s no-hardcoded-`Text` check, which reads only
/// this file).
private func releaseHeaderText(_ release: ChangelogRelease) -> String {
    guard let date = release.date else { return release.version }
    return "\(release.version) (\(date))"
}

/// One bullet's text, "• <scope>: <text>" when the bullet carried a scope
/// prefix, or "• <text>" otherwise — same reasoning as `releaseHeaderText`
/// above. The bullet character is plain text here, not an `Image`, on
/// purpose: `IconTooltipLintTests` requires every SF Symbol icon to carry a
/// hover hint or a documented decorative-icon exemption, and a marker this
/// small and this far from being a hit target is better served by never
/// entering that scan at all.
private func entryText(_ entry: ChangelogRelease.Section.Entry) -> String {
    guard let scope = entry.scope else { return "\u{2022} \(entry.text)" }
    return "\u{2022} \(scope): \(entry.text)"
}

/// Read-only rendering of parsed changelog releases: each release's
/// version/date header, its sections, and each section's bullets, shown
/// AS IS (Global Constraints: "the changelog text is shown as is" — no
/// re-wrapping, truncation, or markdown re-rendering beyond what
/// `ChangelogParser` already reduced).
///
/// Its own view, separate from `WhatsNewSheet` below, so Task 3's Settings
/// pane can present the exact same list without a sheet's chrome (title,
/// Close button) around it.
struct WhatsNewList: View {
    let releases: [ChangelogRelease]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(releases, id: \.version) { release in
                releaseView(release)
            }
        }
    }

    @ViewBuilder
    private func releaseView(_ release: ChangelogRelease) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(releaseHeaderText(release))
                .font(.title3.bold())
            ForEach(Array(release.sections.enumerated()), id: \.offset) { _, section in
                sectionView(section)
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: ChangelogRelease.Section) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !section.title.isEmpty {
                Text(section.title)
                    .font(.headline)
            }
            ForEach(Array(section.entries.enumerated()), id: \.offset) { _, entry in
                Text(entryText(entry))
            }
        }
    }
}

/// "What's New" sheet (What's New plan, Task 2): shown once per version
/// bump, right after `MacSCPApp.init` decides there is something to show —
/// see its own `decideWhatsNew(store:)` doc comment for when the decision
/// is made and why, and `WhatsNewModel.releasesToShow` for which releases
/// end up in `releases`.
///
/// `releases` is expected non-empty whenever `MacSCPApp` presents this
/// sheet (it only sets `showWhatsNew` when `WhatsNewModel` returned
/// something), but the empty case is still handled here rather than
/// assumed away: a `[]` shows the same "nothing shipped" message
/// `ChangelogResource.load()`'s `nil` produces, so a future caller —
/// Task 3's Settings pane, or a test — gets an honest sheet instead of a
/// blank one.
struct WhatsNewSheet: View {
    let currentVersion: String
    let releases: [ChangelogRelease]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(format: L10n.string("whatsNew.title", "What's new in %@"), currentVersion))
                .font(.headline)

            if releases.isEmpty {
                Spacer(minLength: 0)
                Text(L10n.string("whatsNew.none", "No changelog shipped with this build."))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    WhatsNewList(releases: releases)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                Spacer()
                Button(L10n.string("whatsNew.close", "Close")) { onClose() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
    }
}
