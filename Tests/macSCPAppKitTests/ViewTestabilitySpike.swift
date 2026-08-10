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
/// produced a blank bitmap for every input would pass that. Every positive
/// claim here is paired with a discriminating pair: the same view, two
/// inputs, two results that must differ. `sameInputRendersIdentically` is
/// the counterweight, so a "they differ" result cannot be explained by the
/// renderer simply being nondeterministic.
///
/// The suite is serialized because one of its measurements is about
/// process-wide state (`NSApp`), which parallel renders would race on.
@Suite("ViewTestabilitySpike", .serialized)
@MainActor
struct ViewTestabilitySpike {

    // MARK: - Rendering helper

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

    /// Renders a view offscreen. Nil when `ImageRenderer` produced no image.
    ///
    /// The bytes are read back through an explicit `CGContext` rather than
    /// through a PNG encoder, so the comparison sees pixels and not
    /// container metadata.
    private func render<V: View>(_ view: V) -> Bitmap? {
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
            render(searchField(text: "alpha", isRegex: false, errorText: nil))
        )
        #expect(bitmap.width > 0)
        #expect(bitmap.height > 0)
        // Not all-transparent: the view actually drew something.
        #expect(bitmap.bytes.contains { $0 != 0 })
    }

    // MARK: - Step 2.3 — the discriminating pair

    @Test("Two different inputs render to different pixels")
    func differentInputsRenderDifferently() throws {
        let withoutError = try #require(
            render(searchField(text: "alpha", isRegex: false, errorText: nil))
        )
        let withError = try #require(
            render(
                searchField(
                    text: "alpha",
                    isRegex: true,
                    errorText: "Invalid regular expression"
                )
            )
        )
        #expect(withoutError.width == withError.width)
        #expect(withoutError.height == withError.height)
        #expect(withoutError != withError)
    }

    /// The negative control for the test above: identical input must give
    /// identical pixels. Without this, "they differ" could just mean the
    /// renderer is nondeterministic.
    @Test("The same input renders identically twice")
    func sameInputRendersIdentically() throws {
        let first = try #require(
            render(searchField(text: "alpha", isRegex: false, errorText: nil))
        )
        let second = try #require(
            render(searchField(text: "alpha", isRegex: false, errorText: nil))
        )
        #expect(first == second)
    }

    /// A second, independent view — a pure-SwiftUI `ButtonStyle` with no
    /// AppKit-backed control in it — to show the result is not a property of
    /// one lucky view.
    @Test("A pure-SwiftUI style discriminates on its own parameter")
    func buttonStyleDiscriminatesOnItsParameter() throws {
        let prominent = try #require(render(styledButton(prominent: true)))
        let plain = try #require(render(styledButton(prominent: false)))
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
            render(searchField(text: "a", isRegex: false, errorText: nil))
        )
        let long = try #require(
            render(
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
        _ = try #require(render(styledButton(prominent: true)))
        #expect(NSApp === before, "a pure-SwiftUI view must not change the NSApplication state")

        _ = try #require(render(searchField(text: "alpha", isRegex: false, errorText: nil)))
        #expect(NSApp != nil, "TextField/Toggle instantiate the shared NSApplication")
    }
}
