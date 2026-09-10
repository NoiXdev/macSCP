import Foundation
import Testing
@testable import macSCPCore

/// `ShellCompletionRecipe` is the ONE place the three completion lines are
/// spelled (design: "Where the text comes from"), so this suite asserts them
/// verbatim rather than by shape: a line that is merely "plausible" is a line
/// the user pastes into a startup file and never sees fail, because a startup
/// file that errors is quiet.
///
/// Everything here is pure string work — no process, no shell. That the
/// lines actually LOAD in a real interpreter is a different claim, and it is
/// made by `CLICompletionScriptTests` against the built binary.
@Suite("Shell completion recipe")
struct ShellCompletionRecipeTests {
    // MARK: - The three lines

    /// The list is read from `allCases`, not written out, so a fourth shell
    /// added to the enum without a line here goes red instead of unnoticed.
    /// The positive beside it is the count check below: an `allCases` that
    /// somehow came back empty would make this loop assert nothing.
    @Test func everyShellHasItsLineSpelledExactly() {
        let expected: [ShellCompletionRecipe.Shell: String] = [
            .zsh: "source <(macscp-cli --generate-completion-script zsh)",
            .bash: "eval \"$(macscp-cli --generate-completion-script bash)\"",
            .fish: "macscp-cli --generate-completion-script fish | source",
        ]
        for shell in ShellCompletionRecipe.Shell.allCases {
            guard let line = expected[shell] else {
                Issue.record("no expected line written for \(shell.rawValue)")
                continue
            }
            #expect(ShellCompletionRecipe.line(for: shell, tool: "macscp-cli") == line)
        }
    }

    /// The enum IS the shell list the Settings picker iterates, so its
    /// contents are a fact the section depends on. Three, counted here
    /// against `allCases` in the same pass that writes the number
    /// (CLAUDE.md, "Comments that describe other code", rule 2).
    @Test func theShellListIsTheThreeTheCLICanGenerateFor() {
        #expect(ShellCompletionRecipe.Shell.allCases == [.zsh, .bash, .fish])
        #expect(ShellCompletionRecipe.Shell.allCases.count == 3)
    }

    /// The tool token is substituted verbatim: the caller decides whether it
    /// is the bare name or an already-quoted path, and the recipe never
    /// quotes on its own (a token that was quoted twice would be a path the
    /// shell cannot find).
    @Test func theToolTokenIsSubstitutedVerbatim() {
        let quoted = ShellCompletionRecipe.quotedForShell("/Applications/mac SCP.app/Contents/MacOS/macscp-cli")
        #expect(
            ShellCompletionRecipe.line(for: .zsh, tool: quoted)
                == "source <(\(quoted) --generate-completion-script zsh)")
        #expect(
            ShellCompletionRecipe.line(for: .fish, tool: quoted)
                == "\(quoted) --generate-completion-script fish | source")
    }

    // MARK: - Quoting

    /// A space is the ordinary case — `/Applications/mac SCP.app` — and the
    /// single quote is the one that breaks naive quoting. `'\''` (close,
    /// escaped quote, reopen) is the form all three shells accept; fish's
    /// own `\'` inside single quotes would not work in zsh or bash, and the
    /// section shows ONE line per shell built by the same function.
    @Test func aPathWithASpaceIsSingleQuoted() {
        #expect(
            ShellCompletionRecipe.quotedForShell("/Applications/mac SCP.app/Contents/MacOS/macscp-cli")
                == "'/Applications/mac SCP.app/Contents/MacOS/macscp-cli'")
    }

    @Test func anApostropheIsClosedEscapedAndReopened() {
        #expect(
            ShellCompletionRecipe.quotedForShell("/Users/tim's mac/macscp-cli")
                == "'/Users/tim'\\''s mac/macscp-cli'")
    }

    @Test func aPathWithoutSpecialCharactersIsStillQuoted() {
        #expect(ShellCompletionRecipe.quotedForShell("/usr/local/bin/macscp-cli")
            == "'/usr/local/bin/macscp-cli'")
    }

    // MARK: - The login shell

    /// The picker's initial value comes from `$SHELL`, whose value is a
    /// PATH, not a name — and the shell may live anywhere (`/bin/zsh`,
    /// Homebrew's `/opt/homebrew/bin/bash`, `/usr/local/bin/fish`).
    /// Anything unrecognised falls back to zsh, macOS's default login
    /// shell, rather than guessing.
    @Test(arguments: [
        ("/bin/zsh", ShellCompletionRecipe.Shell.zsh),
        ("/opt/homebrew/bin/bash", .bash),
        ("/opt/homebrew/bin/fish", .fish),
        ("/usr/local/bin/fish", .fish),
        ("/bin/sh", .zsh),
        ("/usr/bin/false", .zsh),
        ("", .zsh),
    ])
    func theLoginShellPathPicksTheShell(path: String, expected: ShellCompletionRecipe.Shell) {
        #expect(ShellCompletionRecipe.shell(fromLoginShellPath: path) == expected)
    }

    @Test func noLoginShellAtAllFallsBackToZsh() {
        #expect(ShellCompletionRecipe.shell(fromLoginShellPath: nil) == .zsh)
    }
}
