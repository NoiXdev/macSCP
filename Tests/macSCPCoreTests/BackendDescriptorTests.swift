import Testing
@testable import macSCPCore

@Suite("BackendDescriptor")
struct BackendDescriptorTests {
    @Test func sshCapabilities() {
        let c = BackendDescriptor.descriptor(for: .ssh).capabilities
        #expect(c.supportsShell)
        #expect(c.permissionModel == .posixMode)
        #expect(c.supportsSymlinks)
        #expect(c.atomicRename)
        #expect(c.directoriesAreReal)
        #expect(c.resumeMode == .append)
        #expect(!c.supportsPresignedURL)
        #expect(c.transport == .alwaysEncrypted)
    }

    @Test func s3Capabilities() {
        let c = BackendDescriptor.descriptor(for: .s3).capabilities
        #expect(!c.supportsShell)
        #expect(c.permissionModel == .none)
        #expect(!c.supportsSymlinks)
        #expect(!c.atomicRename)
        #expect(!c.directoriesAreReal)
        #expect(c.resumeMode == .rangeGet)
        #expect(c.supportsPresignedURL)          // capability is TRUE; M14 wires the action
        #expect(c.transport == .optionalTLS)
    }

    @Test func s3SchemaHasProviderPresetsAndSecretField() {
        let schema = BackendDescriptor.descriptor(for: .s3).fieldSchema
        #expect(schema.presets.contains { $0.id == "aws" })
        #expect(schema.presets.contains { $0.id == "hetzner" })
        #expect(schema.presets.contains { $0.id == "custom" })
        #expect(schema.fields.contains { $0.isSecret })   // secret access key
    }
}
