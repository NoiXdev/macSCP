import Citadel
import Foundation
import NIOCore

/// SFTP-Implementierung von RemoteFileSystem auf Basis von Citadel.
/// M1: Passwort-Auth, keine Host-Key-Prüfung (TOFU kommt in M3).
public final class CitadelFileSystem: RemoteFileSystem, @unchecked Sendable {
    private let client: SSHClient
    private let sftp: SFTPClient

    private init(client: SSHClient, sftp: SFTPClient) {
        self.client = client
        self.sftp = sftp
    }

    public static func connect(config: SSHConnectionConfig) async throws -> CitadelFileSystem {
        let authMethod: SSHAuthenticationMethod
        switch config.auth {
        case .password(let password):
            authMethod = .passwordBased(username: config.username, password: password)
        case .privateKey(let keyPath, let passphrase):
            authMethod = try SSHPrivateKeyLoader.authentication(
                username: config.username, keyPath: keyPath, passphrase: passphrase)
        }

        do {
            let client = try await SSHClient.connect(
                host: config.host,
                port: config.port,
                authenticationMethod: authMethod,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
            do {
                let sftp = try await client.openSFTP()
                return CitadelFileSystem(client: client, sftp: sftp)
            } catch {
                try? await client.close()
                throw error
            }
        } catch let error as SSHKeyError {
            throw error
        } catch let error as SSHClientError {
            // Auth-Fehler laufen bei Citadel als allAuthenticationOptionsFailed auf
            // (verifiziert gegen den Docker-Testserver mit falschem Passwort).
            switch error {
            case .allAuthenticationOptionsFailed:
                throw RemoteFSError.authenticationFailed
            default:
                throw RemoteFSError.connectionFailed(reason: String(describing: error))
            }
        } catch let error as RemoteFSError {
            throw error
        } catch {
            throw RemoteFSError.connectionFailed(reason: String(describing: error))
        }
    }

    public func list(path: String) async throws -> [RemoteFileItem] {
        do {
            let names = try await sftp.listDirectory(atPath: path)
            return names
                .flatMap { $0.components }
                .filter { $0.filename != "." && $0.filename != ".." }
                .map { component in
                    SFTPAttributeMapper.item(
                        name: component.filename,
                        directory: path,
                        size: component.attributes.size,
                        permissions: component.attributes.permissions,
                        modifiedAt: component.attributes.accessModificationTime?.modificationTime
                    )
                }
        } catch {
            throw mapSFTPError(error, path: path)
        }
    }

    public func stat(path: String) async throws -> RemoteFileItem {
        do {
            let attributes = try await sftp.getAttributes(at: path)
            let name = path == "/" ? "/" : String(path.split(separator: "/").last ?? "")
            return SFTPAttributeMapper.item(
                name: name,
                directory: RemotePath.parent(of: path),
                size: attributes.size,
                permissions: attributes.permissions,
                modifiedAt: attributes.accessModificationTime?.modificationTime
            )
        } catch {
            throw mapSFTPError(error, path: path)
        }
    }

    /// Übersetzt Citadels rohe SFTP-Status-Fehler in typisierte RemoteFSError.
    /// Der Server antwortet mit SSH_FXP_STATUS; Citadel wirft das als
    /// SFTPMessage.Status mit errorCode (SFTPStatusCode).
    private func mapSFTPError(_ error: Error, path: String) -> Error {
        guard let status = error as? SFTPMessage.Status else {
            return RemoteFSError.protocolError(reason: String(describing: error))
        }
        switch status.errorCode {
        case .noSuchFile: return RemoteFSError.notFound(path: path)
        case .permissionDenied: return RemoteFSError.permissionDenied(path: path)
        default: return RemoteFSError.protocolError(reason: String(describing: status))
        }
    }

    public func readStream(path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let file: SFTPFile
        do {
            file = try await sftp.openFile(filePath: path, flags: .read)
        } catch {
            throw mapSFTPError(error, path: path)
        }
        // Pull-basiert (unfolding): der Konsument bestimmt das Tempo.
        var offset: UInt64 = 0
        return AsyncThrowingStream(unfolding: {
            do {
                let buffer = try await file.read(
                    from: offset, length: UInt32(TransferChunk.size))
                guard buffer.readableBytes > 0 else {
                    try await file.close()
                    return nil
                }
                offset += UInt64(buffer.readableBytes)
                return Data(buffer.readableBytesView)
            } catch {
                try? await file.close()
                throw self.mapSFTPError(error, path: path)
            }
        })
    }

    public func write(path: String, contents: AsyncThrowingStream<Data, Error>) async throws {
        let file: SFTPFile
        do {
            file = try await sftp.openFile(
                filePath: path,
                flags: [.create, .write, .truncate]
            )
        } catch {
            throw mapSFTPError(error, path: path)
        }
        do {
            var offset: UInt64 = 0
            for try await chunk in contents {
                try await file.write(ByteBuffer(bytes: chunk), at: offset)
                offset += UInt64(chunk.count)
            }
            try await file.close()
        } catch {
            try? await file.close()
            throw mapSFTPError(error, path: path)
        }
    }

    public func disconnect() async {
        try? await client.close()
    }
}
