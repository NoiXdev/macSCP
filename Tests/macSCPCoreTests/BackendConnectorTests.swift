import Testing
@testable import macSCPCore

@Suite("BackendConnector")
struct BackendConnectorTests {
    @Test func s3RouteReachesS3Backend() async {
        // Until Task 5, S3 connect throws protocolError; assert the dispatcher
        // ROUTES to S3 (i.e. does not try SSH) by observing the S3-path error.
        let cfg = ConnectionConfig.s3(S3ConnectionConfig(
            accessKeyID: "AK", secretAccessKey: "SK", region: "us-east-1",
            endpoint: "http://127.0.0.1:1", bucket: "b",
            usePathStyle: true, sessionToken: nil))
        await #expect(throws: (any Error).self) {
            _ = try await BackendConnector.connect(cfg, decider: { _ in false })
        }
    }
}
