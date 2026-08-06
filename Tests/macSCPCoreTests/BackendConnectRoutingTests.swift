import Testing
@testable import macSCPCore

/// What is left of `BackendConnectorTests` after the central dispatcher
/// dissolved (M22/T10): the routing it used to perform is now each
/// descriptor's own `connect` closure. The S3 route is still observed the
/// same way, and the guard that matters now is that a closure REFUSES a
/// config of the wrong kind rather than reaching for another backend's
/// fields.
@Suite("BackendDescriptor.connect routing")
struct BackendConnectRoutingTests {
    private let s3Config = ConnectionConfig.s3(S3ConnectionConfig(
        accessKeyID: "AK", secretAccessKey: "SK", region: "us-east-1",
        endpoint: "http://127.0.0.1:1", bucket: "b",
        usePathStyle: true, sessionToken: nil))

    @Test func theS3DescriptorReachesTheS3Backend() async {
        await #expect(throws: (any Error).self) {
            _ = try await BackendDescriptor.descriptor(for: .s3)
                .connect(s3Config, { _ in false }, { _ in false })
        }
    }

    @Test func aMismatchedConfigIsRefusedInsteadOfImprovisedOn() async {
        for kind in [ConnectionKind.ssh, .webdav] {
            await #expect(throws: RemoteFSError.self) {
                _ = try await BackendDescriptor.descriptor(for: kind)
                    .connect(s3Config, { _ in false }, { _ in false })
            }
        }
    }
}
