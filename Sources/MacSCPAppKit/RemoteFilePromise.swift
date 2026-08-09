import AppKit
import UniformTypeIdentifiers
import macSCPCore

/// File promise for remote rows: the Finder receives a promise and calls
/// `writePromiseTo` on drop — only then is the file downloaded. The download
/// runs through `TransferQueueViewModel.enqueueAndWait`, so it queues up
/// serialized with every other transfer (no gate bypass anymore).
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
