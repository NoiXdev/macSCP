import Foundation

/// One line an `ArchiveCommandChannel` will run on the far side.
///
/// `fileprivate init`, exactly as `ChecksumCommandLine` has
/// (`Sources/macSCPCore/RemoteFS/FileChecksum.swift:325`). What that
/// guarantees: no file other than this one can construct an
/// `ArchiveCommandLine`, so a channel taking this type cannot be handed text
/// that did not pass through `remoteCommandLine()`'s quoting.
///
/// What it does NOT guarantee: that every `ArchiveWord` in a plan was
/// written in `ArchivePlan.swift`. `ArchivePlan`'s memberwise initializer is
/// module-internal, so any Core file can build a plan whose `.flag` carries
/// user input, and the rendering writes a `.flag` bare. The residual surface
/// is that initializer and the `.flag`/`.operand` choice at each call site;
/// the module as a whole can also run other text, as `ChecksumCommandLine`'s
/// own documentation admits.
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
    /// because flags are meant to be this project's own words from
    /// `ArchivePlan`. Nothing enforces that: a plan built elsewhere with
    /// user input in a `.flag` renders that input unquoted.
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
