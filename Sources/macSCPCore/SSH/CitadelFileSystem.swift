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

    /// Verbindet mit Trust-on-First-Use-Host-Key-Prüfung.
    ///
    /// - bekannt & identisch → still verbinden
    /// - bekannt & anders → `HostKeyError.mismatch` (der Decider wird NIE gefragt)
    /// - unbekannt → `onUnknownHostKey`; bei `true` → `upsert` + genau EIN Retry,
    ///   bei `false` → `HostKeyError.rejectedByUser` (nichts wird gespeichert)
    ///
    /// Umsetzung (Phase 2 der Drift-Strategie): Citadels Host-Key-Hook ist der
    /// synchrone, Promise-basierte `NIOSSHClientServerAuthenticationDelegate` —
    /// er kann den async-Decider nicht selbst aufrufen. Daher lehnt der Hook
    /// unbekannte/abweichende Keys ab und meldet den Kandidaten über eine Box
    /// nach außen; hier wird der Decider befragt und nach `upsert` erneut
    /// verbunden (dann greift der bekannt-identisch-Pfad still).
    public static func connect(
        config: SSHConnectionConfig,
        knownHosts: KnownHostsStore,
        onUnknownHostKey: @escaping @Sendable (HostKeyCandidate) async -> Bool
    ) async throws -> CitadelFileSystem {
        let box = TOFUHostKeyValidator.Box()
        do {
            return try await attemptConnect(config: config, knownHosts: knownHosts, box: box)
        } catch {
            switch box.result {
            case .mismatch(let host, let expected, let presented):
                // Harter Stopp — kein Override, Decider wird NIE gefragt.
                throw HostKeyError.mismatch(host: host, expected: expected, presented: presented)
            case .lookupFailed(let reason):
                // Korrupter known_hosts-Store → harter, typisierter Fehler statt
                // stillem Downgrade auf TOFU (fail closed).
                throw RemoteFSError.connectionFailed(reason: "known_hosts nicht lesbar: \(reason)")
            case .unknown(let candidate):
                let accepted = await onUnknownHostKey(candidate)
                guard accepted else { throw HostKeyError.rejectedByUser }
                try knownHosts.upsert(KnownHostKey(
                    host: candidate.host, port: candidate.port,
                    keyType: candidate.keyType, publicKeyBase64: candidate.publicKeyBase64))
                // Genau EIN Retry: der Key ist jetzt bekannt → Hook akzeptiert still.
                do {
                    let retryBox = TOFUHostKeyValidator.Box()
                    return try await attemptConnect(
                        config: config, knownHosts: knownHosts, box: retryBox)
                } catch {
                    throw mapConnectError(error)
                }
            case .none:
                // Kein Host-Key-Verdikt → echter Verbindungs-/Auth-/Key-Fehler.
                throw mapConnectError(error)
            }
        }
    }

    /// Ein Verbindungsversuch mit dem TOFU-Validator. Wirft rohe Fehler; die
    /// Auswertung (Decider, Mismatch, Mapping) übernimmt `connect`.
    private static func attemptConnect(
        config: SSHConnectionConfig,
        knownHosts: KnownHostsStore,
        box: TOFUHostKeyValidator.Box
    ) async throws -> CitadelFileSystem {
        let authMethod: SSHAuthenticationMethod
        switch config.auth {
        case .password(let password):
            authMethod = .passwordBased(username: config.username, password: password)
        case .privateKey(let keyPath, let passphrase):
            authMethod = try SSHPrivateKeyLoader.authentication(
                username: config.username, keyPath: keyPath, passphrase: passphrase)
        }

        let validator = TOFUHostKeyValidator(
            host: config.host, port: config.port, knownHosts: knownHosts, box: box)
        let client = try await SSHClient.connect(
            host: config.host,
            port: config.port,
            authenticationMethod: authMethod,
            hostKeyValidator: .custom(validator),
            reconnect: .never
        )
        do {
            let sftp = try await client.openSFTP()
            return CitadelFileSystem(client: client, sftp: sftp)
        } catch {
            try? await client.close()
            throw error
        }
    }

    /// Übersetzt rohe Verbindungs-Fehler in typisierte Fehler (Auth/Key/generisch).
    private static func mapConnectError(_ error: Error) -> Error {
        switch error {
        case let error as SSHKeyError:
            return error
        case let error as HostKeyError:
            return error
        case let error as RemoteFSError:
            return error
        case let error as SSHClientError:
            // Auth-Fehler laufen bei Citadel als allAuthenticationOptionsFailed auf
            // (verifiziert gegen den Docker-Testserver mit falschem Passwort).
            switch error {
            case .allAuthenticationOptionsFailed:
                return RemoteFSError.authenticationFailed
            default:
                return RemoteFSError.connectionFailed(reason: String(describing: error))
            }
        default:
            return RemoteFSError.connectionFailed(reason: String(describing: error))
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

    /// Legt NUR die letzte Ebene an (Eltern müssen existieren — die Rekursion
    /// in T3 läuft top-down). Idempotent: existiert der Pfad bereits als
    /// Verzeichnis (auch bei einem Race zwischen zwei Clients), kehrt der
    /// Aufruf still zurück. Existiert dort eine Datei, wirft `protocolError`.
    public func createDirectory(at path: String) async throws {
        do {
            try await sftp.createDirectory(atPath: path)
        } catch {
            // mkdir kann fehlschlagen, obwohl das Verzeichnis (bereits oder
            // inzwischen) existiert — per stat nachprüfen statt den Fehler
            // blind weiterzureichen.
            if let existing = try? await sftp.getAttributes(at: path) {
                switch SFTPAttributeMapper.kind(fromPermissions: existing.permissions) {
                case .directory:
                    return
                default:
                    throw RemoteFSError.protocolError(reason: "Pfad existiert als Datei: \(path)")
                }
            }
            throw mapSFTPError(error, path: path)
        }
    }

    public func disconnect() async {
        try? await client.close()
    }
}

extension CitadelFileSystem: RemoteShellProvider {
    /// Shell-Channel über DIESELBE Verbindung wie SFTP (Multiplex, wie WinSCP).
    public func openShell(
        terminal: String, cols: Int, rows: Int
    ) async throws -> any RemoteShell {
        try await CitadelShell.open(
            client: client, terminal: terminal, cols: cols, rows: rows)
    }
}
