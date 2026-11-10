import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// The sentence under the "send credentials unencrypted?" question names the
/// scheme the user actually picked: a plain FTP session is told about FTPS,
/// never about `https://`, which FTP does not have.
@Suite("PlaintextConfirmationBody")
struct PlaintextConfirmationBodyTests {
    @Test func theTwoKindsUseTwoDifferentCatalogKeys() {
        let http = PlaintextConfirmationBody.key(for: .http)
        let ftp = PlaintextConfirmationBody.key(for: .plainFTP)
        #expect(http == "transport.plaintext.body")
        #expect(ftp == "transport.plaintext.body.ftp")
    }

    @Test func plainFTPNamesFTPSAndNoHTTPScheme() {
        let text = PlaintextConfirmationBody.text(for: .plainFTP)
        let namesFTPS = text.contains("FTPS")
        let namesHTTP = text.lowercased().contains("http")
        #expect(namesFTPS)
        #expect(namesHTTP == false)
    }

    @Test func theHTTPBodyKeepsNamingTheHTTPSchemes() {
        let text = PlaintextConfirmationBody.text(for: .http)
        let namesBoth = text.contains("http://") && text.contains("https://")
        let namesFTPS = text.contains("FTPS")
        #expect(namesBoth)
        #expect(namesFTPS == false)
    }

    /// The tab carries the kind next to the pending flag, and clears it with
    /// the answer, so the dialog never shows a stale sentence.
    @MainActor
    @Test func theTabCarriesTheKindWhileThePromptIsPending() async {
        let tab = SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in throw CancellationError() }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)

        async let answer = tab.confirmPlaintext(kind: .plainFTP)
        while tab.plaintextConfirmationPending == false { await Task.yield() }
        let carried = tab.plaintextConfirmationKind == .plainFTP
        tab.resolvePlaintextConfirmation(confirmed: true)

        #expect(carried)
        #expect(await answer == true)
        #expect(tab.plaintextConfirmationKind == nil)
    }
}
