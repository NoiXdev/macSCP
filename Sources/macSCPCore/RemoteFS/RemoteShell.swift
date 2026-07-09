import Foundation

/// Eine interaktive Remote-Shell (PTY). Lebt über einer bestehenden
/// Verbindung; `close()` beendet nur die Shell, nie die Verbindung.
public protocol RemoteShell: AnyObject, Sendable {
    /// Byte-Chunks der Shell-Ausgabe. Endet normal, wenn die Shell schließt;
    /// wirft, wenn Shell oder Verbindung fehlschlagen. Genau EIN Konsument.
    var output: AsyncThrowingStream<[UInt8], Error> { get }
    /// Schreibt rohe Eingabe-Bytes (Tastatur) an die Shell.
    func send(_ bytes: [UInt8]) async throws
    /// Meldet eine neue Terminalgröße (SSH window-change).
    func resize(cols: Int, rows: Int) async throws
    /// Schließt die Shell. Idempotent; kehrt erst zurück, wenn der Kanal zu ist.
    func close() async
}

/// Fähigkeit, über eine bestehende Verbindung Shells zu öffnen. Die UI erfragt
/// sie per `as?` vom Remote-Dateisystem (LocalFileSystem hat sie nicht).
public protocol RemoteShellProvider: AnyObject {
    /// Öffnet eine PTY-Shell (TERM=`terminal`) mit initialer Größe.
    func openShell(terminal: String, cols: Int, rows: Int) async throws -> any RemoteShell
}
