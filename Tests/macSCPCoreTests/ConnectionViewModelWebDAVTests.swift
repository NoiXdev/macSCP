import Foundation
import Testing
@testable import macSCPCore

@Suite("ConnectionViewModel WebDAV")
@MainActor
struct ConnectionViewModelWebDAVTests {
    /// `ConnectionViewModel` has no zero-arg initializer (its `connector` is
    /// required, same as `ConnectionViewModelTests.makeVM` needs it) — these
    /// tests only exercise `makeWebDAVConfig(for:)`, never `connect()`, so the
    /// connector is never actually invoked.
    private func makeModel() -> ConnectionViewModel {
        ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem(tree: ["/": []]) })
    }

    /// Builds the runtime WebDAV config through `BackendDescriptor.makeConfig`
    /// — the factory `ConnectionViewModel.makeWebDAVConfig()` wrapped before
    /// M23/P2/T3 retired it as a test-only seam. Unwraps `.webdav` exactly as
    /// the retired wrapper did.
    private func makeWebDAVConfig(for model: ConnectionViewModel) throws -> WebDAVConnectionConfig {
        let config = try BackendDescriptor.descriptor(for: .webdav)
            .makeConfig(model.values, model.values[WebDAVField.password])
        guard case .webdav(let webdav) = config else {
            throw RemoteFSError.protocolError(reason: "expected a WebDAV config")
        }
        return webdav
    }

    @Test func buildsAWebDAVConfigFromTheFormFields() throws {
        let model = makeModel()
        model.kind = .webdav
        model.webdavBaseURL = "https://cloud.example.com"
        model.username = "tim"
        model.password = "app-password"
        model.webdavUseNextcloudPath = true

        let config = try makeWebDAVConfig(for: model)

        #expect(config.baseURL == "https://cloud.example.com")
        #expect(config.username == "tim")
        #expect(config.useNextcloudPath == true)
        #expect(config.password == "app-password")
    }

    /// Trailing whitespace pasted from a browser address bar is the single
    /// most common way this form is filled wrong.
    @Test func baseURLIsTrimmed() throws {
        let model = makeModel()
        model.kind = .webdav
        model.webdavBaseURL = "  https://cloud.example.com  "
        model.username = "tim"
        model.password = "p"

        #expect(try makeWebDAVConfig(for: model).baseURL == "https://cloud.example.com")
    }

    @Test func emptyBaseURLIsRejected() {
        let model = makeModel()
        model.kind = .webdav
        model.webdavBaseURL = "   "
        model.username = "tim"
        model.password = "p"

        #expect(throws: (any Error).self) { _ = try makeWebDAVConfig(for: model) }
    }

    /// The plaintext flag drives the confirmation in Task 10 — it must be a
    /// property of the config, not a check scattered through the UI.
    @Test func plaintextTransportIsFlagged() throws {
        let model = makeModel()
        model.kind = .webdav
        model.webdavBaseURL = "http://nas.local:5005/dav"
        model.username = "tim"
        model.password = "p"

        #expect(try makeWebDAVConfig(for: model).isPlaintextTransport == true)

        model.webdavBaseURL = "https://nas.local:5006/dav"
        #expect(try makeWebDAVConfig(for: model).isPlaintextTransport == false)
    }
}
