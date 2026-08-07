import Foundation
import Testing
@testable import macSCPCore

@Suite("WebDAV registration")
struct WebDAVRegistrationTests {
    /// The point of the whole milestone: two axes flip against S3 while shell
    /// and permissions stay off. If these ever change silently, the framework
    /// claim is no longer true.
    @Test func capabilitiesFlipDirectoriesAndRenameAgainstS3() {
        let webdav = BackendDescriptor.descriptor(for: .webdav).capabilities
        let s3 = BackendDescriptor.descriptor(for: .s3).capabilities

        #expect(webdav.directoriesAreReal == true)
        #expect(webdav.atomicRename == true)
        #expect(s3.directoriesAreReal == false)
        #expect(s3.atomicRename == false)

        #expect(webdav.supportsShell == false)
        #expect(webdav.permissionModel == .none)
        #expect(webdav.supportsSymlinks == false)
        #expect(webdav.resumeMode == .rangeGet)
        #expect(webdav.supportsPresignedURL == false)
        #expect(webdav.transport == .optionalTLS)
    }

    @Test func kindIsCaseIterableAndCodable() throws {
        #expect(ConnectionKind.allCases.contains(.webdav))
        #expect(ConnectionKind(rawValue: "webdav") == .webdav)
    }

    @Test func configReportsItsKind() {
        let config = ConnectionConfig.webdav(WebDAVConnectionConfig(
            baseURL: "https://dav.example.com", username: "u",
            useNextcloudPath: false, password: "p"))
        #expect(config.kind == .webdav)
    }

    /// Username and password moved into `credentialSchema` (M22): a login
    /// belongs to the credential, not the server, and that split is what
    /// lets one generic editor serve WebDAV login sets. This test used to
    /// pin them inside `connectionSchema`; it now pins the opposite, so a
    /// field duplicated into both schemas would fail it.
    @Test func connectionSchemaCarriesTheServerFieldsAndTheNextcloudPresetWhileCredentialsLiveInTheCredentialSchema() {
        let descriptor = BackendDescriptor.descriptor(for: .webdav)
        let schema = descriptor.connectionSchema
        #expect(schema.fields.map(\.id) == ["baseURL", "useNextcloudPath"])
        let nextcloud = schema.presets.first { $0.id == "nextcloud" }
        #expect(nextcloud?.values["useNextcloudPath"] == "true")

        #expect(descriptor.credentialSchema.fields.map(\.id) == ["username", "password"])
        #expect(descriptor.credentialSchema.fields.first { $0.id == "password" }?.isSecret == true)
        #expect(!schema.fields.contains { $0.id == "username" || $0.id == "password" })
    }

    /// A stored WebDAV session must build a runtime config from the Keychain
    /// secret — this is the path the CLI takes for `name:/path`.
    @Test func storedSessionBuildsARuntimeConfig() throws {
        let session = webdavSession(
            name: "cloud",
            config: StoredWebDAVConfig(
                baseURL: "https://cloud.example.com", username: "tim", useNextcloudPath: true))

        let config = try StoredSessionConnectionConfig.build(for: session, secret: "app-password")

        guard case .webdav(let webdav) = config else {
            Issue.record("expected .webdav, got \(config)")
            return
        }
        #expect(webdav.username == "tim")
        #expect(webdav.useNextcloudPath == true)
        #expect(webdav.password == "app-password")
    }

    @Test func storedWebDAVSessionWithoutASecretFails() {
        let session = webdavSession(
            name: "cloud",
            config: StoredWebDAVConfig(
                baseURL: "https://cloud.example.com", username: "tim", useNextcloudPath: true))

        #expect(throws: StoredSessionConnectionError.secretRequired) {
            _ = try StoredSessionConnectionConfig.build(for: session, secret: nil)
        }
    }

    /// A secret-free stored config must round-trip — it lands in the session
    /// JSON and in exports.
    @Test func storedConfigRoundtripsThroughJSON() throws {
        let stored = StoredWebDAVConfig(
            baseURL: "https://cloud.example.com", username: "tim", useNextcloudPath: true)
        let data = try JSONEncoder().encode(stored)
        #expect(try JSONDecoder().decode(StoredWebDAVConfig.self, from: data) == stored)
        // The password must not be encodable at all — StoredWebDAVConfig has
        // no such field, and this is the guard against one being added.
        #expect(String(data: data, encoding: .utf8)?.contains("password") == false)
    }
}
