import Foundation

/// One line an `ArchiveCommandChannel` will run on the far side.
///
/// `fileprivate init`, exactly as `ChecksumCommandLine` has
/// (`Sources/macSCPCore/RemoteFS/FileChecksum.swift:325`): the only code
/// that can phrase an archive command is this file, and this file quotes
/// every operand. A channel therefore cannot be handed a string somebody
/// assembled elsewhere — there is no expression for it.
public struct ArchiveCommandLine: Sendable, Equatable {
    /// The line as the far side's shell will see it.
    public let text: String

    fileprivate init(text: String) {
        self.text = text
    }
}

extension ArchivePlan {
    /// This plan as one shell line.
    ///
    /// An SSH `exec` request is run by the far side through the account's
    /// login shell, so there IS a shell here — unlike the local path — and
    /// the quoting is not optional. Every `.operand` goes through
    /// `PosixQuoting.singleQuoted`; every `.flag` is written as it stands,
    /// because flags are this project's own words from `ArchivePlan` and
    /// nothing else can put one there.
    ///
    /// The `cd` is how a tool is pointed at a directory without a `-C`
    /// every tool here would need; the directory is an operand and is
    /// quoted like any other.
    public func remoteCommandLine() -> ArchiveCommandLine {
        let rendered = words.map { word in
            switch word {
            case .flag(let value): value
            case .operand(let value): PosixQuoting.singleQuoted(value)
            }
        }
        let head = "cd " + PosixQuoting.singleQuoted(workingDirectory)
        return ArchiveCommandLine(
            text: ([head, "&&", tool] + rendered).joined(separator: " "))
    }
}
