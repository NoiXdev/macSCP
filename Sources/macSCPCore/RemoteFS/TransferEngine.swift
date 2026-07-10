import Foundation

public struct TransferProgress: Equatable, Sendable {
    public let bytesTransferred: UInt64
    public let totalBytes: UInt64?
    /// Smoothed transfer rate in bytes/second (M5c/T5). Always `nil` coming
    /// directly from `TransferEngine` — it is computed downstream, in
    /// `TransferQueueViewModel`'s progress consumer, over a sliding window of
    /// samples. Default-`nil` param keeps every existing call site (engine,
    /// tests) source-compatible.
    public let bytesPerSecond: Double?
    /// Estimated seconds remaining (M5c/T5). `nil` until both `totalBytes`
    /// and `bytesPerSecond` are known — same provenance as `bytesPerSecond`
    /// (computed by the queue, never by the engine).
    public let etaSeconds: Double?

    public init(
        bytesTransferred: UInt64, totalBytes: UInt64?,
        bytesPerSecond: Double? = nil, etaSeconds: Double? = nil
    ) {
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.etaSeconds = etaSeconds
    }

    /// Anteil 0…1; nil, wenn die Gesamtgröße unbekannt oder 0 ist.
    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return Double(bytesTransferred) / Double(totalBytes)
    }
}

/// Small `Duration` <-> `Double`-seconds conversions shared by the throttle
/// below and `TransferQueueViewModel`'s rate window (M5c/T5). Internal only —
/// no public API surface needed outside the module.
extension Duration {
    var secondsAsDouble: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    /// Named distinctly from the stdlib's integer-based `Duration.seconds(_:)`
    /// to avoid overload ambiguity.
    static func seconds(fromDouble seconds: Double) -> Duration {
        let secondsComponent = Int64(seconds)
        let attosecondsComponent = Int64(
            (seconds - Double(secondsComponent)) * 1_000_000_000_000_000_000)
        return Duration(secondsComponent: secondsComponent, attosecondsComponent: attosecondsComponent)
    }
}

public enum TransferDirection: Equatable, Sendable {
    case upload
    case download
}

/// Kopiert einzelne Dateien zwischen zwei Dateisystemen (M2c: eine zur Zeit,
/// Ziel wird überschrieben; Konfliktregeln und Queue kommen in M5).
public enum TransferEngine {
    /// Kopiert EINE Datei von source nach destinationDirectory/fileName.
    /// Richtungs-agnostisch (lokal→remote, remote→lokal, remote→remote).
    ///
    /// Wirft der Quell-Stream mitten in der Übertragung, bleiben bereits
    /// geschriebene Ziel-Daten stehen (kein Rollback) — Retry/Cleanup ist
    /// Sache von M5.
    ///
    /// Kooperativer Abbruch (M5c/T2): VOR jedem Chunk-Write wird
    /// `Task.checkCancellation()` geprüft. Wird die umgebende Task abgebrochen
    /// (z. B. via `TransferQueueViewModel.cancelAll`), stoppt die Übertragung
    /// chunk-genau (64 KiB) mit `CancellationError`. Der Abbruch hinterlässt
    /// ggf. eine TEIL-Datei am Ziel; es wird NICHT zurückgerollt — das
    /// Aufräumen (bzw. ein Resume) ist Sache des Aufrufers (M5d).
    /// - Parameters:
    ///   - bytesPerSecondLimit: Bandbreiten-Drossel in Bytes/s (M5c/T5); `0`
    ///     (Default) schaltet sie aus — kein Verhaltensunterschied zu vor T5.
    ///   - sleep: Injizierbarer Schlaf-Hook für die Drossel, Default ein
    ///     echtes `Task.sleep`. Tests ersetzen ihn durch eine zählende
    ///     Attrappe, die NICHT wirklich schläft (kein Flaky-Timing).
    public static func copyFile(
        from source: any RemoteFileSystem, sourcePath: String,
        to destination: any RemoteFileSystem, destinationDirectory: String, fileName: String,
        bytesPerSecondLimit: Int = 0,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        onProgress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        let total = try await source.stat(path: sourcePath).size
        let input = try await source.readStream(path: sourcePath)
        let destinationPath = RemotePath.join(destinationDirectory, fileName)

        // Zähl-Zwischenstück, pull-basiert: das Ziel zieht Chunk für Chunk,
        // nichts wird über einen Chunk hinaus gepuffert.
        var iterator = input.makeAsyncIterator()
        var transferred: UInt64 = 0
        // Drossel-Buchhaltung (M5c/T5): eine rein VIRTUELLE Uhr, die
        // ausschließlich um die Dauern vorrückt, die wir `sleep` übergeben
        // haben — nicht per Wanduhr gemessen. Das macht die Drossel
        // deterministisch testbar (injizierter `sleep`, der nur zählt statt
        // zu schlafen), kostet aber Genauigkeit bei echter Chunk-Latenz: eine
        // ohnehin langsame Verbindung wird ZUSÄTZLICH gedrosselt (nie
        // schneller als das Limit, ggf. langsamer). Einfacher gleitender
        // Ansatz, kein Burst-Bucket (siehe Plan).
        var throttledElapsed = Duration.zero
        let counted = AsyncThrowingStream<Data, Error>(unfolding: {
            // Kooperativer Abbruch VOR jedem Chunk: greift chunk-genau.
            try Task.checkCancellation()
            guard let chunk = try await iterator.next() else { return nil }
            transferred += UInt64(chunk.count)
            onProgress(TransferProgress(bytesTransferred: transferred, totalBytes: total))

            if bytesPerSecondLimit > 0 {
                let targetElapsed = Duration.seconds(
                    fromDouble: Double(transferred) / Double(bytesPerSecondLimit))
                if throttledElapsed < targetElapsed {
                    // WICHTIG: der `checkCancellation` oben deckt den
                    // chunk-genauen Abbruch (M5c/T2) bereits ab. `sleep`
                    // selbst wirft AUCH bei Abbruch der Task (Standardverhalten
                    // von `Task.sleep`) — ein Cancel währenddessen verwirft
                    // diesen Chunk (er wird nie zurückgegeben/geschrieben),
                    // zusätzlich zum obigen Check, nicht an dessen Stelle.
                    try await sleep(targetElapsed - throttledElapsed)
                    throttledElapsed = targetElapsed
                }
            }
            return chunk
        })

        try await destination.write(path: destinationPath, contents: counted)

        // WICHTIG: `AsyncThrowingStream(unfolding:)` BEENDET sich bei Abbruch der
        // konsumierenden Task still (nächstes `next()` liefert `nil`, ohne die
        // Closure erneut aufzurufen) — der obige `checkCancellation` greift dann
        // NICHT. Der Konsum-Loop im Ziel läuft dadurch chunk-genau aus (kein
        // weiterer Chunk wird geschrieben), kehrt aber regulär zurück. Erst
        // dieser Nachcheck macht den Abbruch für den Aufrufer sichtbar: er wirft
        // `CancellationError`, die Queue mappt ihn auf `.cancelled`. Die bereits
        // geschriebene TEIL-Datei bleibt stehen (kein Rollback, s. o.).
        try Task.checkCancellation()
    }
}
