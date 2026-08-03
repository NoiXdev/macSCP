import Foundation

enum CLIEnvironment {
    /// Whether stdin is a terminal. Drives whether we may prompt at all —
    /// checked on stdin rather than stdout so that `macscp-cli ls | less`
    /// still counts as interactive.
    static var hasTTY: Bool { isatty(FileHandle.standardInput.fileDescriptor) == 1 }
}
