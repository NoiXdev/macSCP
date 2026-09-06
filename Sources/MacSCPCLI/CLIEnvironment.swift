import Foundation

enum CLIEnvironment {
    /// Whether stdin is a terminal. Drives whether we may prompt at all —
    /// checked on stdin rather than stdout so that `macscp-cli ls | less`
    /// still counts as interactive.
    static var hasTTY: Bool { isatty(FileHandle.standardInput.fileDescriptor) == 1 }

    /// Puts a yes/no question on the terminal and reads the answer.
    ///
    /// The ONE place this tool asks a person anything. Two callers reach it:
    /// `makeDecider(policy:)`'s prompt branch, which asks about an unknown
    /// host key, and `sessions rm`, which asks before deleting. Counted
    /// 2026-09-06; both are in this target, and there is no third question
    /// anywhere.
    ///
    /// Written to STDERR, like every other diagnostic here, so a question can
    /// never land in the middle of `--json` output someone is piping into
    /// `jq`. The answer comes from stdin, which is what `hasTTY` above is
    /// about: a caller asks that first, and only asks the question when there
    /// is somebody to answer it.
    ///
    /// EOF — a closed or redirected stdin — reads as NO. That is the safe
    /// direction for both callers: an unknown host key stays untrusted, and a
    /// session stays saved. Neither caller relies on it as its refusal, since
    /// both check `hasTTY` before asking.
    ///
    /// Nothing about a SECRET passes through here. This reads one line of
    /// yes-or-no and nothing else: no password, no passphrase, no key
    /// material — those have their own sources
    /// (`--password-command`, the environment) and never a prompt.
    static func confirm(_ question: String) -> Bool {
        FileHandle.standardError.write(Data(question.utf8))
        guard let line = readLine(strippingNewline: true) else { return false }
        let answer = line.lowercased()
        return answer == "y" || answer == "yes"
    }
}
