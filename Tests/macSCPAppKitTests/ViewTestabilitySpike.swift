import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import MacSCPAppKit

/// Spike (2026-08-10): can a real SwiftUI view of this package be exercised
/// from `macSCPAppKitTests` without adding a dependency?
///
/// The question is not "does something come out" — a renderer that silently
/// produced a blank bitmap for every input would pass that. So every positive
/// claim here is a comparison in which **exactly one input differs**, and
/// every such comparison carries an A/B/A control: the first input is
/// rendered again after the second, and must come back byte-identical.
///
/// That control is not ceremony. `ImageRenderer` was measured to return
/// *different* pixels for the same view on the first renders of a process
/// than it does once it has settled (see `renderSettled`), so a naive
/// single-render A/B comparison can report a difference that has nothing to
/// do with its inputs.
///
/// The suite is serialized because one of its measurements is about
/// process-wide state (`NSApp`), which parallel renders would race on.
@Suite("ViewTestabilitySpike", .serialized)
@MainActor
struct ViewTestabilitySpike {

    // MARK: - Rendering helpers

    /// A rendered view as raw premultiplied RGBA pixels.
    ///
    /// Equality compares every pixel, but the printed form is a short
    /// fingerprint — a failing `#expect` on a few hundred thousand raw bytes
    /// would otherwise dump megabytes into the test log.
    private struct Bitmap: Equatable, CustomStringConvertible {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        /// FNV-1a over the pixels. Only ever used for display.
        private var fingerprint: String {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 0x100_0000_01b3
            }
            return String(hash, radix: 16)
        }

        var description: String {
            "Bitmap(\(width)x\(height), \(bytes.count) bytes, fingerprint \(fingerprint))"
        }
    }

    /// Renders a view offscreen exactly once. Nil when `ImageRenderer`
    /// produced no image.
    ///
    /// The bytes are read back through an explicit `CGContext` rather than
    /// through a PNG encoder, so the comparison sees pixels and not
    /// container metadata.
    private func renderOnce<V: View>(_ view: V) -> Bitmap? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return Bitmap(width: width, height: height, bytes: bytes)
    }

    /// Renders a view repeatedly and returns the last result.
    ///
    /// Measured with a throwaway probe, on both a pure-SwiftUI view and one
    /// containing AppKit-backed controls: the first renders of a view in a
    /// process differ from every later render (observed shape: two renders
    /// of one value, then a second value that never changes again). The
    /// difference is real pixels, not noise — it repeats identically across
    /// separate `swift test` runs.
    ///
    /// Discarding the warm-up renders makes results comparable. Because too
    /// short a warm-up would be a silent confound, every comparison in this
    /// suite additionally re-renders its first input at the end; if the
    /// warm-up were ever insufficient, that control turns red rather than
    /// the comparison quietly lying.
    private func renderSettled<V: View>(_ view: V, warmUpRenders: Int = 3) -> Bitmap? {
        for _ in 0..<warmUpRenders {
            guard renderOnce(view) != nil else { return nil }
        }
        return renderOnce(view)
    }

    /// The search field under a fixed frame, so two renders of it are
    /// comparable pixel for pixel.
    private func searchField(text: String, isRegex: Bool, errorText: String?) -> some View {
        SheetSearchField(
            text: .constant(text),
            isRegex: .constant(isRegex),
            errorText: errorText
        )
        .frame(width: 420, height: 40)
    }

    /// A view built only from SwiftUI primitives — no AppKit-backed control
    /// anywhere in it.
    private func styledButton(prominent: Bool) -> some View {
        Button("Connect") {}
            .buttonStyle(PolishedButtonStyle(prominent: prominent))
            .frame(width: 160, height: 40)
    }

    // MARK: - Step 2.1 — does a real view even compile and instantiate here?

    @Test("A real MacSCPAppKit view can be instantiated from the test target")
    func aRealViewCanBeInstantiated() {
        let field = SheetSearchField(
            text: .constant("alpha"),
            isRegex: .constant(false),
            errorText: nil
        )
        #expect(field.text == "alpha")
        #expect(field.isRegex == false)
        #expect(field.errorText == nil)
    }

    // MARK: - Step 2.2 — does ImageRenderer produce anything?

    @Test("ImageRenderer turns that view into a non-empty bitmap")
    func imageRendererProducesANonEmptyBitmap() throws {
        let bitmap = try #require(
            renderSettled(searchField(text: "alpha", isRegex: false, errorText: nil))
        )
        #expect(bitmap.width > 0)
        #expect(bitmap.height > 0)
        // Not all-transparent: the view actually drew something.
        #expect(bitmap.bytes.contains { $0 != 0 })
    }

    // MARK: - Step 2.3 — the discriminating comparison

    /// Exactly one input differs between the two renders: `errorText`.
    /// `text` and `isRegex` are held fixed, so a difference in the pixels can
    /// only be attributed to the error label — and the closing A/B/A control
    /// rules out the renderer having simply moved on between the two.
    @Test("Varying only errorText renders different pixels")
    func varyingOnlyTheErrorTextRendersDifferently() throws {
        let withoutError = try #require(
            renderSettled(searchField(text: "alpha", isRegex: false, errorText: nil))
        )
        let withError = try #require(
            renderSettled(
                searchField(
                    text: "alpha",
                    isRegex: false,
                    errorText: "Invalid regular expression"
                )
            )
        )
        let withoutErrorAgain = try #require(
            renderSettled(searchField(text: "alpha", isRegex: false, errorText: nil))
        )

        #expect(withoutError.width == withError.width)
        #expect(withoutError.height == withError.height)
        #expect(
            withoutError == withoutErrorAgain,
            "A/B/A control: the same input must render identically before and after the other one"
        )
        #expect(withoutError != withError)
    }

    /// The other single-variable half: only `isRegex` differs. Measured, not
    /// assumed — `Toggle` is an AppKit-backed control, and its checked state
    /// therefore stays out of the bitmap, the same way the `TextField`'s text
    /// does. Recording it is what makes the comparison above unambiguous: the
    /// inputs it holds fixed are known quantities, not untested ones.
    @Test("Varying only isRegex leaves the pixels unchanged")
    func varyingOnlyTheRegexToggleRendersIdentically() throws {
        let off = try #require(
            renderSettled(searchField(text: "alpha", isRegex: false, errorText: nil))
        )
        let on = try #require(
            renderSettled(searchField(text: "alpha", isRegex: true, errorText: nil))
        )
        #expect(off == on)
    }

    /// A second, independent view — a pure-SwiftUI `ButtonStyle` with no
    /// AppKit-backed control in it — to show the result is not a property of
    /// one lucky view. Single variable, same A/B/A control.
    @Test("A pure-SwiftUI style discriminates on its own parameter")
    func buttonStyleDiscriminatesOnItsParameter() throws {
        let prominent = try #require(renderSettled(styledButton(prominent: true)))
        let plain = try #require(renderSettled(styledButton(prominent: false)))
        let prominentAgain = try #require(renderSettled(styledButton(prominent: true)))

        #expect(
            prominent == prominentAgain,
            "A/B/A control: the same input must render identically before and after the other one"
        )
        #expect(prominent != plain)
    }

    /// Measures — rather than assumes — whether the text typed into the
    /// AppKit-backed `TextField` reaches the bitmap. `ImageRenderer` is
    /// documented not to render `NSViewRepresentable` content, and
    /// `TextField` is such a control. The expectation below records what was
    /// actually observed; if it ever flips, the note above is stale.
    @Test("TextField content does not reach the bitmap")
    func textFieldContentDoesNotReachTheBitmap() throws {
        let short = try #require(
            renderSettled(searchField(text: "a", isRegex: false, errorText: nil))
        )
        let long = try #require(
            renderSettled(
                searchField(
                    text: "a very much longer needle to search for",
                    isRegex: false,
                    errorText: nil
                )
            )
        )
        #expect(short == long)
    }

    // MARK: - Step 4 — what does this need from the GUI stack?

    /// Measured side effect, isolated with a probe run: rendering a view made
    /// only of SwiftUI primitives leaves the process without an
    /// `NSApplication`, while rendering one that embeds an AppKit-backed
    /// control (`TextField`, `Toggle`) brings the shared application up.
    /// Reading `NSApp` never creates one, so the observation is honest.
    ///
    /// Neither render needs a window, a run loop, or an event; both complete
    /// in a plain `swift test` process.
    @Test("Only AppKit-backed controls bring up an NSApplication")
    func onlyAppKitBackedControlsBringUpAnNSApplication() throws {
        let before = NSApp
        _ = try #require(renderOnce(styledButton(prominent: true)))
        #expect(NSApp === before, "a pure-SwiftUI view must not change the NSApplication state")

        _ = try #require(renderOnce(searchField(text: "alpha", isRegex: false, errorText: nil)))
        #expect(NSApp != nil, "TextField/Toggle instantiate the shared NSApplication")
    }
}
