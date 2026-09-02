import Foundation
import Testing

@testable import macSCPCore

/// Whether the permissions editor is OFFERED follows the capability the
/// descriptor declares — `ChecksumAvailability`'s shape, applied to
/// `ProtocolCapabilities.permissionModel`, which until this suite was read
/// by no surface at all.
@Suite("Permissions availability")
struct PermissionsAvailabilityTests {
    /// The offer follows the declared model and nothing else. A derivation
    /// over every kind rather than three expectations about three
    /// backends, for the reason `ChecksumRequestTests` gives: a `switch`
    /// over `ConnectionKind` would satisfy any list of names written today
    /// and drift the first time a descriptor changes its mind.
    ///
    /// `.posixMode` is the model the editor speaks — an rwx grid and an
    /// octal field — so it is the one the offer is pinned to. `.none` has
    /// nothing to edit; `.acl` would need an editor this app does not have.
    @Test func theOfferIsThePosixModelForEveryBackend() {
        for kind in ConnectionKind.allCases {
            let declared = BackendDescriptor.descriptor(for: kind).capabilities.permissionModel
            #expect(PermissionsAvailability.isOffered(for: kind) == (declared == .posixMode))
        }
    }

    /// The derivation above is satisfied by a function that always answers
    /// the same thing, so this holds it to discriminating at all — S3 and
    /// WebDAV are what make it discriminate today.
    @Test func atLeastOneBackendIsOfferedAndAtLeastOneIsNot() {
        #expect(ConnectionKind.allCases.contains { PermissionsAvailability.isOffered(for: $0) })
        #expect(ConnectionKind.allCases.contains { !PermissionsAvailability.isOffered(for: $0) })
    }

    /// The local pane has no descriptor, so its answer is read off the
    /// local file system's own declaration — and it is a POSIX one, which
    /// is what `LocalFileSystem.setPermissions` writes.
    @Test func theLocalFileSystemDeclaresPosixAndIsOffered() {
        #expect(LocalFileSystem.permissionModel == .posixMode)
        #expect(PermissionsAvailability.isOfferedByTheLocalFileSystem
            == (LocalFileSystem.permissionModel == .posixMode))
        #expect(PermissionsAvailability.isOfferedByTheLocalFileSystem)
    }
}
