import AppKit
import UniformTypeIdentifiers
import macSCPCore

/// File Promise für Remote-Zeilen: Der Finder erhält ein Versprechen und ruft
/// beim Ablegen writePromiseTo auf — erst dann wird die Datei heruntergeladen.
/// Läuft bewusst direkt über die TransferEngine (ohne TransferBar/Queue → M5).
final class RemoteFilePromiseProvider: NSFilePromiseProvider {
    private let strongDelegate: RemoteFilePromiseDelegate

    init(item: RemoteFileItem, download: @escaping @Sendable (RemoteFileItem, URL) async throws -> Void) {
        self.strongDelegate = RemoteFilePromiseDelegate(item: item, download: download)
        super.init()
        let ext = (item.name as NSString).pathExtension
        self.fileType = UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier
        self.delegate = strongDelegate
    }
}

private final class RemoteFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let item: RemoteFileItem
    private let download: @Sendable (RemoteFileItem, URL) async throws -> Void

    init(item: RemoteFileItem, download: @escaping @Sendable (RemoteFileItem, URL) async throws -> Void) {
        self.item = item
        self.download = download
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        item.name
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let item = self.item
        let download = self.download
        Task {
            do {
                try await download(item, url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }
}
