import Foundation
import Security
import Testing
@testable import macSCPCore

/// Runs only with MACSCP_KEYCHAIN=1 (locally) — CI runner keychains are
/// unreliable, and this suite writes to the real login keychain: its own
/// item, under a synthetic server, deleted in a `defer`.
@Suite(
    "CyberduckSecretReader",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_KEYCHAIN"] == "1"),
    .serialized
)
struct CyberduckSecretReaderTests {
    private func bookmark(
        host: String,
        port: Int?,
        username: String?,
        protocolValue: ExternalProtocol
    ) -> ExternalBookmark {
        ExternalBookmark(
            id: "test-id",
            source: "cyberduck",
            nickname: nil,
            protocol: protocolValue,
            host: host,
            port: port,
            username: username,
            keyPath: nil,
            path: nil,
            labels: [],
            fileName: "test.duck",
            unreadable: nil
        )
    }

    /// Writes an Internet-password item under exactly the shape Cyberduck
    /// uses, mirroring `CyberduckSecretReader`'s own query attributes.
    private func addCyberduckItem(
        server: String,
        account: String,
        port: Int,
        protocolAttribute: CFString,
        value: String
    ) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server,
            kSecAttrAccount as String: account,
            kSecAttrPort as String: port,
            kSecAttrProtocol as String: protocolAttribute,
            kSecValueData as String: Data(value.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        query.removeValue(forKey: kSecValueData as String)
        #expect(status == errSecSuccess || status == errSecDuplicateItem)
    }

    private func deleteCyberduckItem(server: String, account: String, protocolAttribute: CFString) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server,
            kSecAttrAccount as String: account,
            kSecAttrProtocol as String: protocolAttribute,
        ]
        SecItemDelete(query as CFDictionary)
    }

    @Test func readsAnSftpItemWrittenInCyberducksShape() async throws {
        let server = "keychain-test.example.net"
        let account = "sftp-user-\(UUID().uuidString.prefix(8))"
        let expected = "s3cr3t-\(UUID().uuidString)"
        try addCyberduckItem(
            server: server, account: account, port: 22,
            protocolAttribute: kSecAttrProtocolSSH, value: expected)
        defer { deleteCyberduckItem(server: server, account: account, protocolAttribute: kSecAttrProtocolSSH) }

        let read = await CyberduckSecretReader().secret(
            for: bookmark(host: server, port: 22, username: account, protocolValue: .sftp))
        // The comparison is computed into a `Bool` BEFORE the expectation:
        // `#expect` reports the SOURCE TEXT of what it checks, so a secret
        // written into the expectation leaks through a failure message.
        let matches = Self.isFound(read, equalTo: expected)
        #expect(matches)
    }

    @Test func readsAnS3ItemWrittenInCyberducksShape() async throws {
        let server = "keychain-test-s3.example.net"
        let account = "AKIA-\(UUID().uuidString.prefix(8))"
        let expected = "s3-secret-\(UUID().uuidString)"
        try addCyberduckItem(
            server: server, account: account, port: 443,
            protocolAttribute: kSecAttrProtocolHTTPS, value: expected)
        defer { deleteCyberduckItem(server: server, account: account, protocolAttribute: kSecAttrProtocolHTTPS) }

        let read = await CyberduckSecretReader().secret(
            for: bookmark(host: server, port: 443, username: account, protocolValue: .s3))
        let matches = Self.isFound(read, equalTo: expected)
        #expect(matches)
    }

    /// A query that RAN and matched nothing. This is the one state the
    /// applier reports to the user, which is why it must be distinguishable
    /// from the two below.
    @Test func missingItemIsNotFound() async {
        let server = "keychain-test-missing.example.net"
        let account = "no-such-account-\(UUID().uuidString.prefix(8))"
        let read = await CyberduckSecretReader().secret(
            for: bookmark(host: server, port: 22, username: account, protocolValue: .sftp))
        #expect(Self.isNotFound(read))
        #expect(Self.isNotAttempted(read) == false)
    }

    @Test func noUsernameIsNotAttemptedAndRunsNoQuery() async throws {
        let server = "keychain-test-nouser.example.net"
        let account = "someone-\(UUID().uuidString.prefix(8))"
        // An item DOES exist for this server, under some account: if the
        // reader queried by server alone — ignoring the bookmark's missing
        // username — it could still find and return this. A bookmark
        // without a username has no account to query with at all, so
        // Cyberduck could never have stored an item for it; the reader
        // must recognize that up front rather than run a query that could
        // accidentally match an unrelated item on the same host.
        try addCyberduckItem(
            server: server, account: account, port: 22,
            protocolAttribute: kSecAttrProtocolSSH, value: "should-never-be-read")
        defer { deleteCyberduckItem(server: server, account: account, protocolAttribute: kSecAttrProtocolSSH) }

        let read = await CyberduckSecretReader().secret(
            for: bookmark(host: server, port: 22, username: nil, protocolValue: .sftp))
        #expect(Self.isNotAttempted(read))
        // The distinction the applier's count hangs on: this is NOT the same
        // answer as "the query ran and found nothing".
        #expect(Self.isNotFound(read) == false)

        // Positive anchor: the item is still there, untouched — proof
        // that the `.notAttempted` above came from the reader skipping the
        // query, not from there being nothing to find.
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server,
            kSecAttrAccount as String: account,
            kSecAttrProtocol as String: kSecAttrProtocolSSH,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let itemStillExists = status == errSecSuccess
        #expect(itemStillExists)
    }

    @Test func unsupportedProtocolIsNotAttempted() async {
        let server = "keychain-test-unsupported.example.net"
        let account = "ftp-user-\(UUID().uuidString.prefix(8))"
        let read = await CyberduckSecretReader().secret(
            for: bookmark(host: server, port: 21, username: account, protocolValue: .unsupported("ftp")))
        #expect(Self.isNotAttempted(read))
        #expect(Self.isNotFound(read) == false)
    }

    // MARK: - Reading a lookup without letting its value out

    /// `CyberduckSecretLookup` is deliberately not `Equatable` and carries no
    /// accessor for its value, so these three read it by pattern-matching and
    /// hand back a `Bool`. The secret never becomes part of an expectation's
    /// source text, and it never becomes part of a failure message.
    private static func isFound(_ lookup: CyberduckSecretLookup, equalTo expected: String) -> Bool {
        guard case .found(let value) = lookup else { return false }
        return value == expected
    }

    private static func isNotFound(_ lookup: CyberduckSecretLookup) -> Bool {
        if case .notFound = lookup { return true }
        return false
    }

    private static func isNotAttempted(_ lookup: CyberduckSecretLookup) -> Bool {
        if case .notAttempted = lookup { return true }
        return false
    }
}
