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
        // AppKit hands the completion handler in as a plain non-`Sendable`
        // closure, and the download that decides its argument can only be
        // awaited from a task — so the handler has to cross into one.
        //
        // Carried in a box rather than marked `nonisolated(unsafe)` here.
        // The marking applies to the binding and does not lift the
        // requirement on what the task's closure CAPTURES: the toolchain
        // used locally proves the capture safe and accepts it, the older one
        // CI builds with does not, and rejected the build. A `Sendable` box
        // is a statement about the type and is read the same way by both.
        let carrier = CompletionCarrier(handler: completionHandler)
        Task {
            do {
                try await download(item, url)
                carrier.finish(nil)
            } catch {
                carrier.finish(error)
            }
        }
    }

    /// Carries AppKit's completion handler into the download task.
    ///
    /// `@unchecked Sendable` because the handler is a plain closure AppKit
    /// gives us and we cannot annotate it. What makes that safe here is not
    /// a promise but the box itself: `finish` takes the handler under a lock
    /// and leaves `nil` behind, so a second call is a no-op rather than a
    /// second delivery, and no two threads can be inside the handler at
    /// once. AppKit's contract is one completion per promise; this makes
    /// over-delivery impossible instead of merely unintended.
    private final class CompletionCarrier: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: ((Error?) -> Void)?

        init(handler: @escaping (Error?) -> Void) {
            self.handler = handler
        }

        func finish(_ error: Error?) {
            lock.lock()
            let handler = self.handler
            self.handler = nil
            lock.unlock()
            handler?(error)
        }
    }
}
