import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Direct tests over `LoginSetRepointPlan.request(...)` — the decision behind
/// whether "Convert key…" asks to update a login set (maintainer decision 1
/// of 2026-09-16) — plus the dialog's catalog text in all four languages.
///
/// Nothing in this project renders SwiftUI, so which buttons the dialog
/// calls is `ConvertKeyWiringGuardTests`' job; this suite proves the value
/// the dialog is built from: nil for every session the question does not
/// apply to, and, for one it does, a request carrying exactly the set, the
/// key, the path and the count it was handed.
@Suite("Login set repoint plan")
@MainActor
struct LoginSetRepointPlanTests {
    private func makeTab() -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                // Never called: nothing here connects.
                throw CancellationError()
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 1)
    }

    private func makeKey() -> ManagedKey {
        ManagedKey(
            name: "converted", comment: "", type: .ed25519, fingerprint: "SHA256:test",
            publicKeyOpenSSH: "ssh-ed25519 AAAA", createdAt: Date(timeIntervalSince1970: 0),
            hasPassphrase: true, fileName: "converted")
    }

    private static let keyPath = "/tmp/macscp-test-keys/converted"

    private func session(boundTo setID: UUID?) -> StoredSession {
        StoredSession(
            name: "bound", loginSetID: setID, kind: .ssh,
            ssh: StoredSSHConfig(host: "host.invalid", username: "u"))
    }

    private func request(
        session: StoredSession?, sets: [LoginSet], usageCount: @escaping (UUID) -> Int = { _ in 1 }
    ) -> LoginSetRepointRequest? {
        LoginSetRepointPlan.request(
            session: session, sets: sets, usageCount: usageCount,
            key: makeKey(), keyPath: Self.keyPath, tab: makeTab())
    }

    @Test func noStoredSessionAsksNothing() {
        let set = LoginSet(name: "team", username: "u", authKind: .privateKey, keyPath: "/old")
        #expect(request(session: nil, sets: [set]) == nil)
    }

    @Test func aSessionWithoutASetAsksNothing() {
        let set = LoginSet(name: "team", username: "u", authKind: .privateKey, keyPath: "/old")
        #expect(request(session: session(boundTo: nil), sets: [set]) == nil)
    }

    /// A set deleted between the failed attempt and the import's end: there
    /// is nothing to update, and the caller's fallback is the attempt-only
    /// route.
    @Test func aSetThatNoLongerExistsAsksNothing() {
        let set = LoginSet(name: "team", username: "u", authKind: .privateKey, keyPath: "/old")
        #expect(request(session: session(boundTo: UUID()), sets: [set]) == nil)
    }

    /// Only an SSH private-key set has a key path a converted key can
    /// replace. A password or agent set has none to re-point, and a set of
    /// another protocol is not an SSH login at all.
    @Test(arguments: [
        LoginSet(name: "pw", username: "u", authKind: .password),
        LoginSet(name: "agent", username: "u", authKind: .agent),
        LoginSet(name: "bucket", username: "u", authKind: .privateKey, keyPath: "/old", kind: .s3),
        LoginSet(name: "share", username: "u", authKind: .privateKey, keyPath: "/old", kind: .webdav),
    ])
    func aSetThatIsNotAnSSHPrivateKeySetAsksNothing(set: LoginSet) {
        #expect(request(session: session(boundTo: set.id), sets: [set]) == nil)
    }

    @Test func anSSHPrivateKeySetAsksWithEverythingTheDialogNeeds() throws {
        let other = LoginSet(name: "other", username: "x", authKind: .privateKey, keyPath: "/other")
        let set = LoginSet(name: "team", username: "u", authKind: .privateKey, keyPath: "/old")
        var askedFor: [UUID] = []
        let made = try #require(request(
            session: session(boundTo: set.id), sets: [other, set],
            usageCount: { id in
                askedFor.append(id)
                return 3
            }))
        #expect(made.set == set)
        #expect(made.key.name == "converted")
        #expect(made.keyPath == Self.keyPath)
        #expect(made.usageCount == 3)
        #expect(askedFor == [set.id])
    }

    /// The tab the request carries is the one handed in — the tab captured
    /// when "Convert key…" was pressed — by identity.
    @Test func theRequestCarriesTheTabItWasMadeFor() throws {
        let set = LoginSet(name: "team", username: "u", authKind: .privateKey, keyPath: "/old")
        let tab = makeTab()
        let made = try #require(LoginSetRepointPlan.request(
            session: session(boundTo: set.id), sets: [set], usageCount: { _ in 1 },
            key: makeKey(), keyPath: Self.keyPath, tab: tab))
        #expect(made.tab === tab)
    }

    // MARK: - The dialog's text, in every catalog

    nonisolated static let languages = ["en", "de", "fr", "pl"]
    static let titleKey = "connection.convertKey.repoint.title %@"
    static let messageKey = "connection.convertKey.repoint.message %lld %@"
    static let confirmKey = "connection.convertKey.repoint.confirm"
    static let thisAttemptKey = "connection.convertKey.repoint.thisAttempt"

    private static func bundle(forLanguage language: String) -> Bundle? {
        guard let path = L10n.bundle.path(forResource: language, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }

    /// The message formats with the count FIRST and the key name SECOND, and
    /// the `one` form names no number at all. Both are the shape that could
    /// quietly print the wrong argument, so each language is formatted the
    /// way the dialog formats it and read back: the key name is in the text
    /// for every count, and 1 reads differently from 3 (and, in Polish, 3
    /// from 5).
    @Test(arguments: LoginSetRepointPlanTests.languages)
    func theMessageNamesTheKeyAndPluralisesTheCount(language: String) throws {
        let languageBundle = try #require(Self.bundle(forLanguage: language))
        let format = NSLocalizedString(Self.messageKey, bundle: languageBundle, value: "", comment: "")
        let locale = Locale(identifier: language)
        let keyName = "KEYNAME"
        let counts = language == "pl" ? [1, 3, 5] : [1, 3]
        let texts = counts.map { String(format: format, locale: locale, $0, keyName) }
        for (count, text) in zip(counts, texts) {
            #expect(text.contains(keyName), "\(language), \(count): \(text)")
            #expect(text.contains("%") == false, "\(language), \(count): \(text)")
        }
        let wordings = Set(texts.map { $0.filter { !$0.isNumber } })
        #expect(wordings.count == counts.count, "\(language): \(texts)")
        let title = String(
            format: NSLocalizedString(Self.titleKey, bundle: languageBundle, value: "", comment: ""),
            locale: locale, "SETNAME")
        #expect(title.contains("SETNAME"), "\(language): \(title)")
        // Every key the dialog reads is in this catalog: a missing one would
        // show the English default in every language.
        let missing = "\u{0}missing"
        for key in [Self.titleKey, Self.messageKey, Self.confirmKey, Self.thisAttemptKey] {
            let value = NSLocalizedString(key, bundle: languageBundle, value: missing, comment: "")
            #expect(value != missing, "\(language) has no entry for \(key)")
        }
    }
}
