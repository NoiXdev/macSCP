import SwiftUI
import macSCPCore

/// The technical text behind the failed-connect surface's details control
/// (failed-connect surface plan, Task 3) — and the reason it lives in a
/// file of its own.
///
/// This is the one place on this branch where a raw error string reaches a
/// surface. Everything else is safe by construction: `ConnectFailureContent`
/// and `LostConnectionContent` have no field a host name, a server message
/// or a typed value could occupy, so "no secret on the surface" is a fact
/// about a type rather than a habit at a call site.
///
/// Round 1 of this task handed `ConnectFailureView` a plain `String?`
/// alongside that content, which gave the surface the structural guarantee
/// and the raw text side by side — and `Text(details ?? L10n.string(
/// content.body.key, …))` then put a server's own message on the general
/// surface with the whole suite green. A scan can be taught to notice that
/// particular spelling; it cannot be taught to notice the next one.
///
/// So the string is `fileprivate`, and the only view that can read it —
/// `ConnectFailureDetailsSheet`, below — is in this same file.
/// `ConnectFailureView` lives in `ContentView+Detail.swift` and holds one
/// of these.
///
/// ## Where the boundary actually runs
///
/// Two spellings of rendering it on the general surface fail to COMPILE,
/// measured both ways round: `Text(details ?? …)` fails on the type, and
/// `Text(details?.text ?? …)` fails on the access level.
///
/// A third one compiles, and used to leak. Review round 1 measured
/// `Text(String(describing: details))` in `ConnectFailureView` compiling
/// and the whole suite staying green — because reflection ignores access
/// levels. Without a `CustomStringConvertible`, `String(describing:)`
/// falls back to a `Mirror` over the STORAGE and prints
/// `ConnectFailureDetailText(text: "…")`, raw message and all; plain
/// interpolation, `"\(details)"`, goes down the same road. `fileprivate`
/// closes NAMED access and nothing else, and this file used to claim more
/// than that.
///
/// So the type answers reflection itself, with a placeholder rather than
/// the message:
///
/// - `CustomStringConvertible` catches `String(describing:)`, `print` and
///   every string interpolation.
/// - `CustomDebugStringConvertible` catches `String(reflecting:)` and
///   `debugPrint`, which consult that protocol FIRST and would otherwise
///   reach the same mirror.
/// - `CustomReflectable` catches `dump(_:)` and a hand-written
///   `Mirror(reflecting:)` label lookup — the one this suite's own "what
///   this guard cannot see" list calls exotic, and the only remaining way
///   to walk the storage generically.
///
/// What is still NOT covered, stated as plainly as the rest: this file.
/// Anyone editing it can add an accessor, or make one of the three
/// conformances above return the real string, and the type system will
/// not object. `ReconnectWiringGuardTests
/// .theDetailsTextHasNoWayOutOfItsOwnFile` is the check for that, and it
/// is a scan over this file's shape — a guard against an edit, not a
/// guarantee about one.
struct ConnectFailureDetailText: Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    /// `fileprivate`, not `private`: `private` is scoped to the enclosing
    /// declaration, which would shut the dialog below out too. The scope
    /// that matches the guarantee is exactly this file — the reader above
    /// and the one view allowed to render it, and nothing else in the
    /// module.
    fileprivate let text: String

    /// What every generic way of turning this value into a string gets:
    /// the type's name, and no message.
    ///
    /// Not localized and not meant to be read by a user — it is what
    /// appears if someone renders this value by accident, and its job is
    /// to be obviously a placeholder rather than to be helpful. The one
    /// place the real string belongs on screen is
    /// `ConnectFailureDetailsSheet` below, which reads the storage by
    /// name.
    ///
    /// Deliberately carries nothing derived from the message — not its
    /// length, not whether it is empty. A placeholder that varied with the
    /// text would be a smaller leak rather than none, and this type's
    /// whole point is that "no secret on the surface" is a fact about it
    /// rather than a habit at a call site.
    private static let placeholder = "ConnectFailureDetailText(hidden)"

    var description: String { Self.placeholder }

    var debugDescription: String { Self.placeholder }

    /// An empty mirror, so `dump(_:)` and a hand-written
    /// `Mirror(reflecting:)` walk over the children find no `text` to
    /// read. `displayStyle` stays `nil`: a `.struct` style with no
    /// children invites a reader to conclude the value is empty, which is
    /// a different false claim.
    var customMirror: Mirror { Mirror(self, children: []) }

    /// The message `ConnectionViewModel` published, unchanged — the same
    /// text the connection form has always shown, whose producing sites
    /// this branch's groundwork task audited and repaired (a password in a
    /// base URL's userinfo, credentials sent to a redirect target, a
    /// certificate pinned for an attacker-chosen host).
    ///
    /// Deliberately incapable of enriching: it takes the message and
    /// nothing else. The `field` a failure carries is meaningful only to
    /// the on-screen form and is dropped here rather than appended.
    /// Reaching past this for a rawer form of the error — a
    /// `String(describing:)` of the thrown value, say, or the config that
    /// was dialed — would put text on screen that no audit covered, which
    /// is the one way this dialog could become the leak the rest of the
    /// branch was spent closing.
    ///
    /// `nil` for any state that is not a failure: there is nothing
    /// technical to show, and a dialog with an empty body is a worse
    /// answer than no dialog.
    static func read(from state: ConnectionViewModel.State) -> ConnectFailureDetailText? {
        guard case .failed(let message, _) = state else { return nil }
        return ConnectFailureDetailText(text: message)
    }
}

/// The failed-connect details dialog (failed-connect surface plan, Task 3):
/// the full technical message, for debugging — the maintainer's decision
/// that the surface carries one general sentence and everything precise
/// sits one click away.
///
/// The only view in the app that can read `ConnectFailureDetailText`'s
/// string, which is what being in this file buys. It does nothing to it:
/// no trimming, no prefix, no label woven into the text.
///
/// `textSelection` because the point of the dialog is to get the text INTO
/// a bug report, and a scrolling body because a server's own refusal text
/// has no length this layout could assume.
struct ConnectFailureDetailsSheet: View {
    /// The dialog's headline, a catalog key like every other fixed string
    /// on this surface — see `ConnectFailureContent.detailsTitle`.
    let title: ConnectFailureContent.Message
    let details: ConnectFailureDetailText
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string(title.key, title.fallback))
                .font(.headline)
            ScrollView {
                Text(details.text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 80, maxHeight: 220)
            HStack {
                Spacer()
                Button(L10n.string("common.ok", "OK"), action: onClose)
                    .buttonStyle(.polished)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420, maxWidth: 520)
    }
}
