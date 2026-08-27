import Foundation

/// The one symbol the executable target needs. Everything else in this
/// module stays `internal`.
///
/// `MacSCPApp` itself is deliberately NOT made `public`: the `App` protocol
/// requires `body`, so a public conformer would force `public` onto `body`
/// and its whole scene tree — spreading access widening through the UI for
/// no benefit. A wrapper keeps the widening at exactly one symbol.
///
/// `App.main()` is the standard programmatic entry point; the executable
/// calls it instead of carrying `@main` on the app struct, because that
/// attribute has to sit in the executable target.
///
/// Main-actor isolated because `App.main()` is: the wrapper has to carry the
/// same isolation it forwards to, and the process entry point is the main
/// thread by definition.
public enum AppMain {
    @MainActor
    public static func main() {
        MacSCPApp.main()
    }
}
