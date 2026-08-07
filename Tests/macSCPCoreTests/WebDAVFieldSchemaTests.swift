import Foundation
import Testing
@testable import macSCPCore

@Suite("WebDAVFieldSchema")
struct WebDAVFieldSchemaTests {
    private func filledValues() -> FieldValues {
        var values = FieldValues()
        values[WebDAVField.baseURL] = "https://cloud.example.com"
        values[WebDAVField.username] = "tim"
        values[bool: WebDAVField.useNextcloudPath] = true
        return values
    }

    @Test func schemaCoversEveryDeclaredField() {
        #expect(SchemaConformance.check(
            BackendDescriptor.descriptor(for: .webdav), fields: WebDAVField.self).isEmpty)
    }

    /// Username and password are the login; the URL and the Nextcloud toggle
    /// describe the server. This split is what makes a WebDAV login set work
    /// with no WebDAV-specific UI.
    @Test func credentialSchemaCarriesOnlyTheLoginFields() {
        let ids = Set(BackendDescriptor.descriptor(for: .webdav).credentialSchema.fields.map(\.id))
        #expect(ids == [WebDAVField.username.rawValue, WebDAVField.password.rawValue])
    }

    @Test func makeConfigBuildsAWebDAVConfig() throws {
        let config = try WebDAVFieldSchema.makeConfig(filledValues(), "app-password")
        guard case .webdav(let dav) = config else {
            Issue.record("expected .webdav, got \(config)")
            return
        }
        #expect(dav.baseURL == "https://cloud.example.com")
        #expect(dav.username == "tim")
        #expect(dav.useNextcloudPath == true)
        #expect(dav.password == "app-password")
    }

    /// A URL pasted from a browser address bar routinely carries trailing
    /// whitespace.
    @Test func makeConfigTrimsTheBaseURL() throws {
        var values = filledValues()
        values[WebDAVField.baseURL] = "  https://cloud.example.com  "
        let config = try WebDAVFieldSchema.makeConfig(values, "p")
        guard case .webdav(let dav) = config else {
            Issue.record("expected .webdav")
            return
        }
        #expect(dav.baseURL == "https://cloud.example.com")
    }

    @Test func makeConfigRejectsAnEmptyBaseURL() {
        var values = filledValues()
        values[WebDAVField.baseURL] = "   "
        #expect(throws: (any Error).self) { _ = try WebDAVFieldSchema.makeConfig(values, "p") }
    }

    @Test func valuesRoundTripThroughTheStoredConfig() {
        let back = WebDAVFieldSchema.values(from: WebDAVFieldSchema.stored(from: filledValues()))
        #expect(back[WebDAVField.baseURL] == "https://cloud.example.com")
        #expect(back[WebDAVField.username] == "tim")
        #expect(back[bool: WebDAVField.useNextcloudPath] == true)
    }

    @Test func theRoundTripDropsTheSecret() {
        var values = filledValues()
        values[WebDAVField.password] = "app-password"
        let back = WebDAVFieldSchema.values(from: WebDAVFieldSchema.stored(from: values))
        #expect(back[WebDAVField.password] == "")
    }

    /// Trimming on write (M23/T7 fix round 1) — the App's WebDAV save branch
    /// trimmed both of these; see `S3FieldSchemaTests.theStoredConfigTrimsEveryTextField`
    /// for the full reasoning. `useNextcloudPath` is a Bool and has nothing to
    /// trim.
    @Test func theStoredConfigTrimsEveryTextField() {
        var values = filledValues()
        values[WebDAVField.baseURL] = " https://cloud.example.com \n"
        values[WebDAVField.username] = "  tim "
        let stored = WebDAVFieldSchema.stored(from: values)
        #expect(stored.baseURL == "https://cloud.example.com")
        #expect(stored.username == "tim")
    }

    @Test func displaySummaryNamesTheUserAndHost() {
        #expect(WebDAVFieldSchema.displaySummary(filledValues()) == "tim @ cloud.example.com")
    }
}
