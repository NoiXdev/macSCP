import SwiftUI
import macSCPCore

/// What a pane shows while it stands at a list of containers that holds
/// nothing: an account whose first bucket has not been made yet.
///
/// **Why it exists.** Task 6 removed the `RemoteFSError.bucketListEmpty`
/// refusal so that an account with no buckets can connect at all, which is
/// what makes a first bucket creatable. Spec §6.1's sentence for that task is
/// that "the empty state it creates must offer the one action that resolves it
/// rather than being blank", and `RemoteBrowserViewModel.State` has no empty
/// case: a zero-bucket account reaches `.loaded` with zero rows, and
/// `BrowserPane` drew an overlay only for `.loading` and `.failed`. So the
/// flow this branch unlocked ended on an empty table with column headers, no
/// sentence and no visible button. F3 of the final whole-branch review.
///
/// **The action is the menu's, routed through the menu's own code.** The
/// button builds no sheet. It calls back to the pane's owner, which hands the
/// request to `ContentView.handleConnectionAction` exactly as the toolbar row
/// does, so the availability rule and the sheet's construction stay spelled
/// once (`ConnectionActionRoute.createBucket`). `onCreate` is `nil` wherever
/// there is nobody to route it to, and the notice is then its sentences alone
/// -- which still says what is going on, where a blank table said nothing.
///
/// **A `BoundedView` on purpose.** Nothing here has been seen on screen, in
/// any language, and the layout guard is the only reader this text has: the
/// registry entry measures all four catalogues against `bound`. The bound is a
/// cap rather than a width because the pane is resizable, and its maximum sits
/// inside `BrowserPane.minimumWidth` so the notice fits the narrowest pane a
/// person can drag to.
struct EmptyContainerListView: BoundedView {
    /// The size `EmptyContainerListView` bounds itself to, applied with
    /// `.sheetBound(Self.bound)`. The maximum is 20 pt inside
    /// `BrowserPane.minimumWidth` (280), so the notice never asks for more
    /// room than the pane can be squeezed to.
    static let bound: SheetBound = .capped(minWidth: 220, maxWidth: 260)

    /// Whether a pane shows this instead of an empty table.
    ///
    /// All three facts are needed and none implies another. The root lists
    /// containers AND the pane is standing at that list
    /// (`BrowserScope.isContainerListRoot`, the same question
    /// `CreateBucketModel.isOffered` asks, so the notice cannot appear
    /// somewhere the action it offers is unavailable); the listing has
    /// LOADED, because an empty array before a listing arrives, or after one
    /// failed, is not "no buckets"; and it holds nothing.
    ///
    /// `listedItemCount` is the count of `RemoteBrowserViewModel.listedItems`
    /// and not of `items`: `items` is the listing after the search filter, and
    /// a search that matches no bucket is not an account without any. The
    /// create-bucket sheet reads the same property for the same reason
    /// (`CreateBucketModel.listing(of:)`).
    nonisolated static func isShown(
        scope: BrowserScope, state: RemoteBrowserViewModel.State, listedItemCount: Int
    ) -> Bool {
        scope.isContainerListRoot && state == .loaded && listedItemCount == 0
    }

    /// What the button does, or `nil` where nothing routes it.
    let onCreate: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(Self.titleLine.text)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.bodyLine.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let onCreate {
                // The menu row's own title, read from the sheet that row
                // opens rather than spelled again: the button and the row a
                // person may already have found are the same action, and a
                // second copy of the name is a rename waiting to diverge.
                Button(CreateBucketModel.titleLine.text, action: onCreate)
                    .buttonStyle(.polishedProminent)
            }
        }
        .padding(16)
        .sheetBound(Self.bound)
    }

    // MARK: - What it says

    static let titleLine = CatalogueLine(
        key: "browser.pane.noContainers.title", english: "No buckets yet")
    /// Says what the account has and what resolves it, without naming where
    /// the menu row is: the button beside this sentence IS the offer, and a
    /// sentence pointing at a toolbar menu would be a direction to follow
    /// instead of a thing to press.
    static let bodyLine = CatalogueLine(
        key: "browser.pane.noContainers.body",
        english: "This account has no buckets. Create one to start keeping files here.")

    /// Every line this view can show. The create button's title is
    /// `CreateBucketModel.titleLine`, covered by that sheet's own catalogue
    /// checks, so it is not repeated here.
    static var allLines: [CatalogueLine] { [titleLine, bodyLine] }
}
