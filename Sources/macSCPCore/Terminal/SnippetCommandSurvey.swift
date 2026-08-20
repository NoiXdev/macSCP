import Foundation

/// A conservative reading of a snippet command: which spans of it are
/// positions where a value quoted by `PosixQuoting.singleQuoted` is
/// *provably* still one literal word — and, when the text cannot be read
/// that far, what stopped the reading.
///
/// ## Why this is not the highlighter
///
/// `SnippetHighlighter` answers a colouring question, and a colouring
/// question tolerates approximation: a token boundary a shade off is
/// invisible. This type answers a security question, where the same
/// approximation decides whether a typed value is data or code. Every review
/// round that broke this gate broke it through exactly that gap — the
/// tokenizer did not understand a construct, and *not understanding meant
/// accepting*. Sharing one recogniser between the two meant a change made
/// for colour could move the gate, silently.
///
/// So there is no shared code with `SnippetHighlighter`, on purpose. The
/// duplication (both know what a quoted span is) is the price of the two
/// being able to answer to different masters: the highlighter may keep
/// approximating, this one may not.
///
/// ## The rule that makes it fail closed
///
/// `survey` never returns "nothing found, carry on". It returns either the
/// spans it positively recognised — and a position covered by no span is
/// not safe — or a `Refusal`. Every construct whose effect on quoting this
/// type cannot state exactly is a `Refusal`: a here-document, a command
/// substitution, a subshell, an expansion other than a plain `$NAME`, a
/// quote that does not close on its line, a command name it cannot read as
/// a literal word, a `eval`-style re-parse of its own arguments, a dangling
/// escape. Breadth of acceptance is explicitly not a goal; a legitimate
/// command refused is a nuisance, a hostile one accepted is a shell running
/// a stranger's text.
///
/// This is deliberately NOT a shell parser. It reads a small, flat subset —
/// words, separators, redirections, comments, quoted spans — and refuses
/// everything else. Nesting of any kind is a refusal rather than a
/// recursion.
///
/// ## The alphabet it reads in
///
/// `Unicode.Scalar`, for the reasons `ShellScalar` sets out. Reading shell
/// text in `Character`s meant a quote carrying a combining mark was one
/// symbol that compared unequal to `"'"`, so this type stayed in the
/// unquoted state across it and emitted an `.argument` span over a
/// placeholder a shell reads as quoted. Positive recognition does not save
/// you there: the span is not missing, it is *wrong*. Containment in one
/// span can only be as good as the span.
///
/// ## And its predicates are `bash`'s, not Unicode's
///
/// The unit is half the answer. A scalar predicate that recognises a
/// lexical event `bash` does not is the same defect in a new spelling: the
/// placeholder lands in a context modelled wrongly, and a wrong model here
/// resolves to acceptance. Each predicate this type reads shell text with —
/// what ends a line, what separates words — was run through `/bin/bash` and
/// matched to what `bash` actually did; where the answers differed, the
/// predicate moved to `bash`'s. `ShellScalar` records those measurements
/// next to the predicates themselves.
public enum SnippetCommandSurvey {
    /// What stopped the reading. Each case names a construct, not a
    /// mistake: every one of these is a perfectly good thing to write in a
    /// shell — it is this type that cannot survey it.
    public enum Refusal: Equatable, Sendable {
        /// A here-document operator (`<<`, `<<-`, `<<<`). Its body is a
        /// quoting context of its own, delimited by a word rather than by a
        /// character, and nothing here can express that.
        case heredoc
        /// A quoted span that never closes, or one that runs across a line
        /// break. Either way the quoting state of every later position
        /// would be a guess.
        case unbalancedQuoting
        /// `$(…)`, a backtick, `(…)`, or a process substitution `<(…)`,
        /// `>(…)`: a command inside a command. Its text has its own quoting
        /// state, and a value placed anywhere near it would be read by a
        /// shell twice.
        case commandSubstitution
        /// An expansion other than a plain `$NAME` or `$1`: `${…}`, `$((…))`,
        /// `$'…'`, `$"…"`, or a `$` this type cannot read at all.
        case expansion
        /// A command name from `reparsingCommands` — one where the shell
        /// itself turns an argument into shell code: at once (`eval`), on a
        /// later signal (`trap`), out of a file it names (`source`), through
        /// an option that makes the next argument a variable NAME the shell
        /// then evaluates (`printf -v`, `test -v`), or by reading an
        /// argument as arithmetic (`let`, and every counted builtin in zsh).
        /// Quoting a value into one literal word protects nothing when the
        /// word is then handed back to the parser.
        case evaluation
        /// The text ran out mid-construct, or a shape appeared that no rule
        /// here covers — including a command name that is not a plain
        /// literal word. The structural default, and the case that makes
        /// "not recognised" mean "refused" rather than "accepted".
        case unrecognizedSyntax
    }

    /// What a recognised span of text *is*. Only `.argument` is a position
    /// where a single-quoted value stays one literal word.
    public enum Placement: Equatable, Sendable {
        /// Unquoted literal text inside a word that is an argument of a
        /// top-level simple command. The one safe placement.
        case argument
        /// Inside a single- or double-quoted span. A single-quoted value
        /// placed here contributes its quotes as literal characters while
        /// anything live inside it stays live.
        case quoted
        /// The word a shell would run as the command itself, or an
        /// assignment prefix standing in front of it. A value here would
        /// name the program rather than be handed to one.
        case commandName
        /// A `#` comment, to the end of its line. Unsafe despite looking
        /// inert: a value containing a newline ends the comment, and
        /// everything after the newline is code again.
        case comment
        /// The word after a redirection operator. Not an argument of the
        /// command, and refused rather than reasoned about.
        case redirectionTarget
    }

    /// One recognised span of `command`.
    public struct Span: Equatable, Sendable {
        public let placement: Placement
        public let range: Range<String.Index>

        public init(placement: Placement, range: Range<String.Index>) {
            self.placement = placement
            self.range = range
        }
    }

    /// The whole answer: spans, or the reason there are none.
    public enum Reading: Equatable, Sendable {
        /// Every span the reading positively recognised. Text covered by no
        /// span was reached but not classified, and is therefore not safe —
        /// the caller must require containment, never absence of a hit.
        case surveyed([Span])
        case refused(Refusal)
    }

    /// Reads `command` and reports the spans it recognised, or refuses.
    public static func survey(_ command: String) -> Reading {
        var reader = Reader(text: command)
        return reader.read()
    }

    /// Whether `range` sits entirely inside one recognised `.argument`
    /// span. Containment in ONE span is the requirement, not overlap with
    /// several: a `{{NAME}}` straddling a quote boundary, an escape, or a
    /// word break is exactly the shape no rule here classifies, and it must
    /// come out unsafe.
    public static func placement(
        of range: Range<String.Index>, in spans: [Span]
    ) -> Placement? {
        spans.first {
            $0.range.lowerBound <= range.lowerBound && range.upperBound <= $0.range.upperBound
        }?.placement
    }
}

extension SnippetCommandSurvey {
    /// What a shell does with a word in COMMAND-NAME position, and where
    /// that answer comes from. The one place this project decides which
    /// snippets it will send.
    ///
    /// ## The shell this is about is not the shell on this machine
    ///
    /// A resolved snippet does not run here. `ContentView.runSnippet` hands
    /// it to the terminal panel, `CitadelShell` writes it into the PTY it
    /// opened with `withPTY`, and what reads it is the LOGIN SHELL OF THE
    /// REMOTE HOST — some version of bash, or zsh, or something else again.
    /// macSCP does not know which and cannot find out. So the guarantee this
    /// table backs is a guarantee about what macSCP REFUSES TO SEND. What
    /// the far side does with what it does send is the far side's, and no
    /// table here can speak for it.
    ///
    /// An earlier version of this classification was called complete by
    /// construction because it was checked against `compgen -b` from the
    /// `/bin/bash` installed on the developer's Mac. That asked the wrong
    /// shell. macOS pins `/bin/bash` at 3.2.57 and CI runs on macOS, so no
    /// test in this repository could ever observe the difference — and
    /// `[ -v {{X}} ]`, `test -v {{X}}` and `printf -v {{X}} …` passed that
    /// gate while creating the marker on bash 5.2 and, for `printf`, on zsh.
    /// An imported snippet reading as innocently as "is this variable set?"
    /// ran an attacker's command on the first click of Run.
    ///
    /// ## Where the authority comes from now
    ///
    /// From execution against the shells a server plausibly runs — bash
    /// 3.2.57 (this Mac), bash 4.4 and bash 5.2.37 (containers), zsh 5.9 —
    /// and never from whichever binary happens to sit on the machine running
    /// the tests. Each entry carries its own evidence: `.executed` names the
    /// shell and the shape that created the marker, `.sweptInert` means the
    /// whole option sweep ran in every one of those shells and left none,
    /// and `.reasoned` is the honest label for a behaviour no shell here can
    /// be made to demonstrate — an interactive-only builtin, a module that
    /// would have to exist — where the reason, not a measurement, is the
    /// authority. A `.reasoned` entry is never a conclusion of "inert".
    ///
    /// ## The posture is the union, and it costs something
    ///
    /// If ANY plausible shell re-parses, macSCP refuses. Being harmless on
    /// bash 3.2.57 is not evidence about a Linux server. That decision is
    /// what moves `test`, `[`, `printf`, `export` and the numeric builtins
    /// out of the accepted set, and it is paid for in real snippets:
    /// `[ -f {{PATH}} ]`, `printf '%s\n' {{X}}` and `export FOO={{VALUE}}`
    /// can no longer be saved with a placeholder in them. Over-refusing is
    /// the direction this branch takes when the two disagree.
    ///
    /// ## The command name alone is not the question
    ///
    /// The finding that produced this table was option-shaped: `-v` turns
    /// the FOLLOWING argument into a variable NAME, and bash evaluates an
    /// array subscript inside a name as arithmetic, which expands a command
    /// substitution. So the classification was decided by sweeping every
    /// name in the table against every single-letter option in both cases,
    /// in five argument positions (bare, after the option, after the option
    /// with a trailing word, before the option, attached to the option) and
    /// with four payload shapes — a substitution, a subscript, an assignment
    /// through a subscript, and a bare command word for options that take a
    /// callback. What that sweep found beyond the names already refused:
    /// `-v` on `printf` and `test` (a name), `-C` and `-W` on `compgen` and
    /// `-C` on `mapfile`/`readarray` (a command), `-A` on zsh's `set`, `-a`
    /// on `zparseopts` and `zformat`, `-g` on `zstyle` (a name), and — the
    /// mechanism with the widest reach — zsh reading a builtin's NUMERIC
    /// argument as arithmetic, which fires `break`, `continue`, `return`,
    /// `shift`, `exit`, `logout` and `bye`. Bracketed `[ … ]` and the
    /// second-argument name of `getopts` are shapes a flat sweep cannot
    /// spell, and were measured separately.
    ///
    /// A rule that modelled the OPTION rather than the name was considered
    /// and dropped: it would need a per-builtin option grammar including
    /// clustering, attached values and `--`, and a reader that misreads that
    /// grammar accepts — which is the failure mode this whole type exists to
    /// remove.
    ///
    /// ## What `compgen` does now
    ///
    /// It is a LOWER BOUND and never a licence. `everyLocalShellWordIsInTheTable`
    /// asks the installed `bash` for its builtins and reserved words and
    /// fails if any of them is missing from this table, so a name macSCP has
    /// never seen still goes red. It cannot make a name safe: safety comes
    /// from an entry with evidence, written by a person who ran something.
    ///
    /// ## The boundary this table does NOT reach
    ///
    /// It is the set where the SHELL re-parses. It is emphatically not a
    /// list of every danger: a PROGRAM that interprets its own argument —
    /// `bash -c`, `sh -c`, `python -c`, `perl -e`, `awk`, `find -exec`,
    /// `xargs`, an `ssh` command string — reads a perfectly quoted word as
    /// code, and no quoting rule reaches inside it. Those are out of scope
    /// by standing decision. `jobs -x` is the one BUILTIN of that shape:
    /// measured, `jobs -x ./evil` execs the program the value names. It
    /// stays classified as not re-parsing because that is what it does — the
    /// shell parses nothing again and the value stays exactly one word, so
    /// `jobs -x 'touch M'` looks for a program called `touch M` and finds
    /// none — but the value does reach command-name position, and this
    /// paragraph rather than the verdict is where that is written down.
    enum Verdict: Sendable, Equatable {
        /// The shell itself turns an argument into shell code — at once, or
        /// on a later signal, or out of a file it names, or by reading a
        /// name or a number as something it evaluates. Refused.
        case reparses
        /// The word AFTER this one is what the shell runs, so the reader
        /// keeps expecting a command name. The strict direction: it makes
        /// the next word be checked instead of accepted.
        case introducesACommandName
        /// Reserved-word syntax this reader does not model at all. Refused
        /// rather than read on, because reading on is what turns "no rule
        /// for this" into acceptance.
        case unmodelledSyntax
        /// A reserved word that takes a WORD rather than a command name.
        /// Read as an ordinary command, which is what it behaves like here.
        case takesAWordNotACommandName
        /// Measured not to turn an argument into shell code.
        case doesNotReparse
    }

    /// Where an entry's verdict comes from. The distinction is the point of
    /// the table: a shell that could not be made to show a behaviour is not
    /// a shell that showed the behaviour absent.
    enum Evidence: Sendable, Equatable {
        /// A marker was created. The string names the shell and the shape.
        case executed(String)
        /// The option sweep ran in every listed shell and produced none.
        case sweptInert
        /// No shell available here can demonstrate it. The string is the
        /// reason, and the reason is what the verdict rests on.
        case reasoned(String)
    }

    /// One name and what the plausible target shells do with it.
    struct Fact: Sendable {
        let name: String
        let verdict: Verdict
        let evidence: Evidence

        init(_ name: String, _ verdict: Verdict, _ evidence: Evidence) {
            self.name = name
            self.verdict = verdict
            self.evidence = evidence
        }
    }

    /// The checked-in classification. Its scope is the union of the builtins
    /// and reserved words of bash 3.2, bash 4.4, bash 5.x and zsh — a name
    /// only one of them has still belongs here, because the shell on the
    /// other end may be that one.
    static let shellVocabulary: [Fact] = [
        Fact("eval", .reparses, .executed("every shell: eval '$(touch M)'")),
        Fact("let", .reparses, .executed("every shell: let 'a[$(touch M)]'")),
        Fact("command", .reparses, .executed("every shell: command eval 'touch M'")),
        Fact("builtin", .reparses, .executed("every shell: builtin eval 'touch M'")),
        Fact("source", .reparses, .executed("every shell: source a file holding touch M")),
        Fact(".", .reparses, .executed("every shell: . a file holding touch M")),
        Fact("trap", .reparses, .executed("every shell: trap 'touch M' EXIT")),
        Fact("alias", .reparses, .executed("every shell: alias a='touch M', then a")),
        Fact("emulate", .reparses, .executed("zsh 5.9: emulate zsh -c 'touch M'")),
        Fact("declare", .reparses, .executed("every shell: declare 'x[$(touch M)]=1'")),
        Fact("typeset", .reparses, .executed("every shell: typeset 'x[$(touch M)]=1'")),
        Fact("local", .reparses,
             .executed("bash 3.2/4.4/5.2 in a function: local 'x[$(touch M)]=1'")),
        Fact("unset", .reparses,
             .executed("every shell, with an array set: unset 'a[$(touch M)]'")),
        Fact("export", .reparses, .executed("zsh 5.9: export 'a[$(touch M)]'")),
        Fact("private", .reparses, .executed("zsh 5.9: private 'a[$(touch M)]'")),
        Fact("read", .reparses, .executed("every shell: read 'a[$(touch M)]'")),
        Fact("getln", .reparses, .executed("zsh 5.9: getln 'a[$(touch M)]'")),
        Fact("getopts", .reparses, .executed("zsh 5.9: getopts ab 'a[$(touch M)]'")),
        Fact("set", .reparses, .executed("zsh 5.9: set -A 'a[$(touch M)]' x")),
        Fact("printf", .reparses, .executed("bash 4.4/5.2, zsh 5.9: printf -v 'a[$(touch M)]'")),
        Fact("print", .reparses, .executed("zsh 5.9: print -v 'a[$(touch M)]' y")),
        Fact("test", .reparses, .executed("bash 4.4/5.2: test -v 'a[$(touch M)]'")),
        Fact("[", .reparses, .executed("bash 4.4/5.2: [ -v 'a[$(touch M)]' ]")),
        Fact("compgen", .reparses, .executed("every bash: compgen -C 'touch M' / -W '$(touch M)'")),
        Fact("mapfile", .reparses, .executed("bash 4.4/5.2: mapfile -C 'touch M' -c 1 arr")),
        Fact("readarray", .reparses, .executed("bash 4.4/5.2: readarray -C 'touch M' -c 1 arr")),
        Fact("zstyle", .reparses, .executed("zsh 5.9: zstyle -g 'a[$(touch M)]'")),
        Fact("zformat", .reparses, .executed("zsh 5.9: zformat -a 'a[$(touch M)]' …")),
        Fact("zparseopts", .reparses, .executed("zsh 5.9: zparseopts -a 'a[$(touch M)]'")),
        Fact("break", .reparses,
             .executed("zsh 5.9: break 'x[$(touch M)]=1' — the count is arithmetic")),
        Fact("continue", .reparses, .executed("zsh 5.9: continue 'x[$(touch M)]=1' — likewise")),
        Fact("return", .reparses, .executed("zsh 5.9: return 'x[$(touch M)]=1' — likewise")),
        Fact("shift", .reparses, .executed("zsh 5.9: shift 'x[$(touch M)]=1' — likewise")),
        Fact("exit", .reparses, .executed("zsh 5.9: exit 'x[$(touch M)]=1' — likewise")),
        Fact("logout", .reparses, .executed("zsh 5.9: logout 'x[$(touch M)]=1' — likewise")),
        Fact("bye", .reparses, .executed("zsh 5.9: bye 'x[$(touch M)]=1' — likewise")),
        Fact("readonly", .reparses,
             .reasoned("zsh spells it typeset -r, and typeset and export both fire there")),
        Fact("bind", .reparses,
             .reasoned("binds a key to a command line an interactive shell later runs")),
        Fact("bindkey", .reparses, .reasoned("zsh's bind; -s pushes its argument back as input")),
        Fact("complete", .reparses, .reasoned("-C names a command run to produce completions")),
        Fact("compctl", .reparses,
             .reasoned("zsh's complete; -K names a function run to complete")),
        Fact("fc", .reparses, .reasoned("-s re-runs a history entry with substitutions applied")),
        Fact("r", .reparses, .reasoned("zsh's fc -s under a shorter name")),
        Fact("history", .reparses,
             .reasoned("-s pushes a line into the history an interactive shell re-runs")),
        Fact("enable", .reparses, .reasoned("-f loads a builtin out of a shared object")),
        Fact("zmodload", .reparses,
             .reasoned("zsh's enable -f; loads a module and can alias parameters")),
        Fact("zcompile", .reparses,
             .reasoned("compiles shell code into a file the shell later reads")),
        Fact("autoload", .reparses,
             .reasoned("marks a name the shell later loads as code out of fpath")),
        Fact("functions", .reparses,
             .reasoned("-M defines a math function the shell calls from arithmetic")),
        Fact("sched", .reparses,
             .reasoned("stores a command line the shell runs at a later prompt")),
        Fact("zle", .reparses, .reasoned("-N names a widget function the line editor later runs")),
        Fact("vared", .reparses,
             .reasoned("edits a named parameter, the shape read is measured on")),
        Fact("float", .reparses, .reasoned("a typeset variant, and typeset is measured")),
        Fact("integer", .reparses, .reasoned("a typeset variant, and typeset is measured")),
        Fact("zregexparse", .reparses,
             .reasoned("its actions are shell code the builtin evaluates")),
        Fact("compadd", .reparses,
             .reasoned("a completion-widget builtin: names parameters it assigns through")),
        Fact("comparguments", .reparses,
             .reasoned("a completion-widget builtin: names parameters it assigns through")),
        Fact("compcall", .reparses,
             .reasoned("a completion-widget builtin: names parameters it assigns through")),
        Fact("compdescribe", .reparses,
             .reasoned("a completion-widget builtin: names parameters it assigns through")),
        Fact("compfiles", .reparses,
             .reasoned("a completion-widget builtin: names parameters it assigns through")),
        Fact("compgroups", .reparses,
             .reasoned("a completion-widget builtin: names parameters it assigns through")),
        Fact("compquote", .reparses,
             .reasoned("a completion-widget builtin: names parameters it assigns through")),
        Fact("compset", .reparses,
             .reasoned("a completion-widget builtin: names parameters it assigns through")),
        Fact("comptags", .reparses,
             .reasoned("a completion-widget builtin: names parameters it assigns through")),
        Fact("comptry", .reparses,
             .reasoned("a completion-widget builtin: names parameters it assigns through")),
        Fact("compvalues", .reparses,
             .reasoned("a completion-widget builtin: names parameters it assigns through")),
        Fact("if", .introducesACommandName, .reasoned("bash and zsh read a command name after it")),
        Fact("then", .introducesACommandName, .reasoned("likewise")),
        Fact("elif", .introducesACommandName, .reasoned("likewise")),
        Fact("else", .introducesACommandName, .reasoned("likewise")),
        Fact("fi", .introducesACommandName, .reasoned("likewise")),
        Fact("while", .introducesACommandName, .reasoned("likewise")),
        Fact("until", .introducesACommandName, .reasoned("likewise")),
        Fact("do", .introducesACommandName, .reasoned("likewise")),
        Fact("done", .introducesACommandName, .reasoned("likewise")),
        Fact("esac", .introducesACommandName, .reasoned("likewise")),
        Fact("time", .introducesACommandName, .reasoned("likewise")),
        Fact("coproc", .introducesACommandName, .reasoned("likewise")),
        Fact("!", .introducesACommandName, .reasoned("likewise")),
        Fact("{", .introducesACommandName, .reasoned("likewise")),
        Fact("}", .introducesACommandName, .reasoned("likewise")),
        Fact("end", .introducesACommandName,
             .reasoned("zsh closes foreach with it, and a command name follows")),
        Fact("exec", .introducesACommandName,
             .reasoned("a builtin, but the word after it is the command name")),
        Fact("noglob", .introducesACommandName,
             .reasoned("zsh precommand modifier: the word after it is the command name")),
        Fact("nocorrect", .introducesACommandName, .reasoned("zsh precommand modifier: likewise")),
        Fact("-", .introducesACommandName,
             .reasoned("zsh runs the following command name as a login shell")),
        Fact("[[", .unmodelledSyntax, .executed("every bash: [[ 1 -eq 'a[$(touch M)]' ]]")),
        Fact("]]", .unmodelledSyntax,
             .reasoned("a reader that refuses the opener cannot claim to know the closer")),
        Fact("repeat", .unmodelledSyntax,
             .reasoned("zsh reads an arithmetic count and then a command name")),
        Fact("case", .takesAWordNotACommandName,
             .executed("matches the word against patterns; no marker")),
        Fact("in", .takesAWordNotACommandName, .executed("introduces a word list; no marker")),
        Fact("for", .takesAWordNotACommandName,
             .executed("a payload in that position is a syntax error")),
        Fact("select", .takesAWordNotACommandName, .executed("likewise")),
        Fact("function", .takesAWordNotACommandName, .executed("names a function; no marker")),
        Fact("foreach", .takesAWordNotACommandName,
             .executed("zsh's for; its ( … ) list refuses the command anyway")),
        Fact(":", .doesNotReparse, .sweptInert),
        Fact("bg", .doesNotReparse, .sweptInert),
        Fact("caller", .doesNotReparse, .sweptInert),
        Fact("cd", .doesNotReparse, .sweptInert),
        Fact("chdir", .doesNotReparse, .sweptInert),
        Fact("compopt", .doesNotReparse, .sweptInert),
        Fact("dirs", .doesNotReparse, .sweptInert),
        Fact("disable", .doesNotReparse, .sweptInert),
        Fact("disown", .doesNotReparse, .sweptInert),
        Fact("echo", .doesNotReparse, .sweptInert),
        Fact("echotc", .doesNotReparse, .sweptInert),
        Fact("echoti", .doesNotReparse, .sweptInert),
        Fact("false", .doesNotReparse, .sweptInert),
        Fact("fg", .doesNotReparse, .sweptInert),
        Fact("hash", .doesNotReparse, .sweptInert),
        Fact("help", .doesNotReparse, .sweptInert),
        Fact("jobs", .doesNotReparse, .sweptInert),
        Fact("kill", .doesNotReparse, .sweptInert),
        Fact("limit", .doesNotReparse, .sweptInert),
        Fact("log", .doesNotReparse, .sweptInert),
        Fact("popd", .doesNotReparse, .sweptInert),
        Fact("pushd", .doesNotReparse, .sweptInert),
        Fact("pushln", .doesNotReparse, .sweptInert),
        Fact("pwd", .doesNotReparse, .sweptInert),
        Fact("rehash", .doesNotReparse, .sweptInert),
        Fact("setopt", .doesNotReparse, .sweptInert),
        Fact("shopt", .doesNotReparse, .sweptInert),
        Fact("suspend", .doesNotReparse, .sweptInert),
        Fact("times", .doesNotReparse, .sweptInert),
        Fact("true", .doesNotReparse, .sweptInert),
        Fact("ttyctl", .doesNotReparse, .sweptInert),
        Fact("type", .doesNotReparse, .sweptInert),
        Fact("ulimit", .doesNotReparse, .sweptInert),
        Fact("umask", .doesNotReparse, .sweptInert),
        Fact("unalias", .doesNotReparse, .sweptInert),
        Fact("unfunction", .doesNotReparse, .sweptInert),
        Fact("unhash", .doesNotReparse, .sweptInert),
        Fact("unlimit", .doesNotReparse, .sweptInert),
        Fact("unsetopt", .doesNotReparse, .sweptInert),
        Fact("wait", .doesNotReparse, .sweptInert),
        Fact("whence", .doesNotReparse, .sweptInert),
        Fact("where", .doesNotReparse, .sweptInert),
        Fact("which", .doesNotReparse, .sweptInert),
    ]

    /// Command names where the shell turns an argument into shell code.
    /// Derived from `shellVocabulary` so the table is the only place a
    /// verdict is written down.
    static let reparsingCommands: Set<String> = names(with: .reparses)

    /// Words after which the next word is still a command name. Missing an
    /// entry over-refuses; a wrong extra entry cannot open a hole, because
    /// expecting a command name only ever adds checks.
    static let commandIntroducers: Set<String> = names(with: .introducesACommandName)

    /// Reserved words this reader does not model, refused when they would be
    /// the command name.
    static let unmodelledKeywords: Set<String> = names(with: .unmodelledSyntax)

    /// Every name the table classifies, for the lower-bound test.
    static let classifiedShellWords: Set<String> = Set(shellVocabulary.map(\.name))

    private static func names(with verdict: Verdict) -> Set<String> {
        Set(shellVocabulary.lazy.filter { $0.verdict == verdict }.map(\.name))
    }

    /// The single left-to-right pass. Kept as a struct with one cursor so
    /// there is exactly one notion of "where we are" — the earlier design
    /// derived quoting state from a token list produced elsewhere, and the
    /// gap between "how the tokenizer split it" and "how a shell reads it"
    /// is where every past escape lived.
    ///
    /// It holds the command's `String.UnicodeScalarView` and NOT the
    /// `String`. Scalar-view indices are `String.Index` values, so the spans
    /// handed out stay comparable with ranges a caller found by ordinary
    /// text search.
    ///
    /// An earlier version of this comment claimed that holding only the
    /// scalar view made a `Character` comparison unwritable in here. It did
    /// not: a helper built a `String` out of the cursor's scalars, and
    /// `word.contains("=")` was written against that `String` — a
    /// `Character` test, sitting one line below a scalar test of the same
    /// `=`, disagreeing with it, and accepting `A=̈1 eval {{X}}` because it
    /// disagreed. The route is closed now by giving the helper a return type
    /// with no character access at all (`ShellWord`), so the claim is about
    /// a type rather than about a habit.
    private struct Reader {
        let scalars: String.UnicodeScalarView
        var index: String.Index
        var spans: [Span] = []
        /// True where the next word would be the command a shell runs.
        var expectsCommandName = true
        /// True immediately after a redirection operator.
        var expectsRedirectionTarget = false

        init(text: String) {
            self.scalars = text.unicodeScalars
            self.index = text.startIndex
        }

        mutating func read() -> Reading {
            while index < scalars.endIndex {
                let scalar = scalars[index]

                if ShellScalar.isLineFeed(scalar) {
                    advance()
                    beginCommand()
                    continue
                }
                if ShellScalar.isBlank(scalar) {
                    advance()
                    continue
                }
                // A `#` that reaches the top of this loop always begins a
                // comment, exactly as a shell has it, because every path
                // back to the top is a word boundary. Counted rather than
                // recalled, there are seven of them: the start of the text,
                // a line feed, an unquoted blank, a `#` comment, a
                // separator, a redirection operator, and the return from
                // `readWord`. The last two are the ones an earlier version
                // of this list left out, and both are still boundaries: the
                // comment branch stops ON a line feed or at the end of the
                // text, and `readWord` never breaks on `#`, so neither can
                // carry a mid-word `#` up here. A `#` in the MIDDLE of a word never
                // arrives here — `readWord` does not treat `#` as a word
                // terminator, so it is consumed inside the word and
                // `echo a#b` passes a literal `a#b`. That, and nothing
                // else, is what stops a mid-word `#` from being read as a
                // comment; reading it as one let a batch of templates
                // through a previous round.
                //
                // The comment then runs to the next LINE FEED and to
                // nothing else, because that is where `bash` ends one —
                // measured, not assumed (`ShellScalar.isLineFeed`). Ending
                // it at a CR, a VT, a NEL or a U+2028 the way
                // `Character.isNewline` would meant reading the rest of
                // `bash`'s comment as a fresh command and the placeholder
                // in it as an argument, while `bash` kept the value inside
                // the comment — where a value carrying a newline reopens
                // code. Running off the end of the text without finding a
                // line feed is the correct outcome, not a missing case: the
                // comment reaches the end for `bash` too.
                if scalar == "#" {
                    let start = index
                    while index < scalars.endIndex, !ShellScalar.isLineFeed(scalars[index]) {
                        advance()
                    }
                    spans.append(Span(placement: .comment, range: start..<index))
                    continue
                }
                if scalar == ";" || scalar == "&" || scalar == "|" || scalar == ")" {
                    advance()
                    beginCommand()
                    continue
                }
                if scalar == "(" || scalar == "`" {
                    return .refused(.commandSubstitution)
                }
                if scalar == "<" || scalar == ">" {
                    if let refusal = readRedirectionOperator(scalar) {
                        return .refused(refusal)
                    }
                    continue
                }
                if let refusal = readWord() {
                    return .refused(refusal)
                }
            }
            return .surveyed(spans)
        }

        private mutating func advance() {
            index = scalars.index(after: index)
        }

        private mutating func beginCommand() {
            expectsCommandName = true
            expectsRedirectionTarget = false
        }

        /// The scalars of `start..<end` as a `ShellWord` — a whole word, for
        /// comparison against a keyword set and for nothing else.
        ///
        /// It returns `ShellWord` rather than `String` because the `String`
        /// this used to return was the way back into the wrong alphabet:
        /// `word.contains("=")` was a `Character` test written against a
        /// cursor that is otherwise scalars all the way down. `ShellWord`
        /// offers no character access, so the same line does not compile any
        /// more. Built through the scalar view rather than by subscripting
        /// the original `String`, because a scalar-aligned index need not sit
        /// on a grapheme cluster boundary and slicing a `String` at one is
        /// not a well-defined thing to ask for.
        private func word(from start: String.Index, to end: String.Index) -> ShellWord {
            ShellWord(scalars[start..<end])
        }

        /// Whether the word `start..<end` contains a `=` SCALAR anywhere.
        ///
        /// The loose companion to `opensAssignment`, and loose on purpose:
        /// a false positive here only keeps the reader expecting a command
        /// name, which makes the NEXT word be checked as one instead of
        /// accepted as an argument. A false NEGATIVE is the unsafe
        /// direction, and it is what a `Character` `contains("=")` produced
        /// for `A=̈1`: `bash` reads that as an assignment (measured — the
        /// variable is set and the mark lands in its value), so `eval` after
        /// it is the command name, while the cluster test said "no `=`
        /// here" and handed `eval` on as an ordinary argument.
        ///
        /// Asking it in scalars also makes it a provable superset of
        /// `opensAssignment`, which scans the same scalars for the same `=`:
        /// wherever that one is true, this one is true too, so the branch
        /// that skips the command-name checks can never be the branch that
        /// also stops expecting a command name.
        private func containsAssignmentScalar(from start: String.Index, to end: String.Index)
            -> Bool {
            scalars[start..<end].contains { $0 == "=" }
        }

        /// `<`, `<<`, `<<<`, `>`, `>>` and the process substitutions that
        /// open with them. `<<` in any of its forms is a here-document —
        /// the two characters are read here, in the unquoted state, so a
        /// `<<` inside a string or a comment never reaches this branch.
        private mutating func readRedirectionOperator(_ scalar: Unicode.Scalar) -> Refusal? {
            let next = scalars.index(after: index)
            if next < scalars.endIndex {
                if scalar == "<", scalars[next] == "<" { return .heredoc }
                if scalars[next] == "(" { return .commandSubstitution }
            }
            advance()
            if scalar == ">", index < scalars.endIndex, scalars[index] == ">" { advance() }
            expectsRedirectionTarget = true
            return nil
        }

        /// One word: its literal runs, its quoted spans, its expansions.
        ///
        /// The word ends at a blank, at a line feed, or at any unquoted
        /// metacharacter, which is left for `read()` to classify — this
        /// method never consumes a separator. That is `bash`'s word
        /// boundary and no other: a CR, a VT, a form feed or a U+00A0 are
        /// ordinary word content, measured by printing the argument vector
        /// `bash` builds for `a<scalar>b`. Splitting a word `bash` keeps
        /// whole would put the tail of a command NAME into argument
        /// position, which is the wrong side to be wrong on.
        private mutating func readWord() -> Refusal? {
            let placement: Placement =
                expectsRedirectionTarget ? .redirectionTarget
                : expectsCommandName ? .commandName : .argument
            let wordStart = index
            var runStart: String.Index? = index
            var isPlainLiteral = true

            while index < scalars.endIndex {
                let scalar = scalars[index]
                if ShellScalar.endsAWord(scalar) || scalar == ";" || scalar == "&"
                    || scalar == "|" || scalar == "<" || scalar == ">"
                    || scalar == "(" || scalar == ")" || scalar == "`" {
                    break
                }
                if scalar == "'" || scalar == "\"" {
                    closeRun(&runStart, placement: placement)
                    isPlainLiteral = false
                    if let refusal = readQuotedSpan(quoteScalar: scalar) { return refusal }
                    runStart = index
                    continue
                }
                if scalar == "\\" {
                    closeRun(&runStart, placement: placement)
                    isPlainLiteral = false
                    let escaped = scalars.index(after: index)
                    // A backslash with nothing after it is the text running
                    // out mid-construct, which is a refusal and not a
                    // literal backslash.
                    guard escaped < scalars.endIndex else { return .unrecognizedSyntax }
                    index = scalars.index(after: escaped)
                    runStart = index
                    continue
                }
                if scalar == "$" {
                    closeRun(&runStart, placement: placement)
                    isPlainLiteral = false
                    if let refusal = readExpansion() { return refusal }
                    runStart = index
                    continue
                }
                advance()
            }
            closeRun(&runStart, placement: placement)

            if placement == .commandName {
                let word = word(from: wordStart, to: index)
                // A word a shell reads as an assignment is not a command
                // name at all, so it need not be readable as one:
                // `PGPASSWORD='secret' psql -h {{HOST}}` is an everyday
                // snippet, and requiring a plain literal here refused the
                // whole command over the quotes around `secret`. The value
                // side stays fully surveyed — its literal runs are
                // `.commandName` and its quoted spans are `.quoted`, so a
                // placeholder *inside* the assignment is still refused, and
                // anything the value contains that this type cannot read
                // (`$(…)`, a backtick, `${…}`) still refuses the command.
                //
                // The test for "this is an assignment" is the STRICT one
                // (`opensAssignment`: a POSIX identifier then `=`, read out
                // of plain literal scalars), because it is the test that
                // lets a word through without the name checks below.
                if !opensAssignment(from: wordStart) {
                    // A command name that is not one plain literal word
                    // cannot be compared against the re-parsing set at all,
                    // and a name this type cannot read is precisely the
                    // "unknown shape" case that must land on refusal.
                    // `"eval" {{X}}` is the shape that makes this
                    // load-bearing rather than tidy.
                    guard isPlainLiteral else { return .unrecognizedSyntax }
                    if word.isOneOf(SnippetCommandSurvey.reparsingCommands) {
                        return .evaluation
                    }
                    // A reserved word this reader does not model. Refused
                    // here rather than read on as an ordinary command,
                    // because reading on is what turns "we have no rule for
                    // this" into acceptance.
                    if word.isOneOf(SnippetCommandSurvey.unmodelledKeywords) {
                        return .unrecognizedSyntax
                    }
                }
                // An assignment prefix (`DB=x cmd …`) and a word that
                // introduces another command both leave the command name
                // still to come — so the next word gets read as a name and
                // checked against the re-parsing set instead of being
                // accepted as an argument.
                //
                // Both questions about this word's `=` are now asked in the
                // same alphabet: `opensAssignment` above and
                // `containsAssignmentScalar` here read the same scalars, so
                // the strict test cannot say "assignment, skip the checks"
                // while the loose one says "no assignment, stop expecting a
                // name". Those two answers disagreeing over a `=` carrying a
                // combining mark is precisely how `A=̈1 eval {{X}}` was
                // accepted and ran its payload.
                if !containsAssignmentScalar(from: wordStart, to: index),
                   !word.isOneOf(SnippetCommandSurvey.commandIntroducers) {
                    expectsCommandName = false
                }
            }
            expectsRedirectionTarget = false
            return nil
        }

        /// Whether the word starting at `start` is what a shell reads as an
        /// assignment: a POSIX identifier (`[A-Za-z_][A-Za-z0-9_]*`)
        /// followed by `=`, spelled in plain literal scalars.
        ///
        /// Read from the raw scalars rather than from the assembled word,
        /// so a quote, an escape or a `$` anywhere in the name makes it
        /// false: `"A"=1 cmd` is refused as an unreadable command name even
        /// though a shell may treat it as an assignment. Over-refusing is
        /// the safe direction for a test whose true answer skips checks.
        private func opensAssignment(from start: String.Index) -> Bool {
            var scan = start
            guard scan < index, ShellScalar.isASCIILetterOrUnderscore(scalars[scan])
            else { return false }
            scan = scalars.index(after: scan)
            while scan < index,
                  ShellScalar.isASCIILetterOrUnderscore(scalars[scan])
                  || ShellScalar.isASCIIDigit(scalars[scan]) {
                scan = scalars.index(after: scan)
            }
            return scan < index && scalars[scan] == "="
        }

        private mutating func closeRun(_ runStart: inout String.Index?, placement: Placement) {
            if let start = runStart, start < index {
                spans.append(Span(placement: placement, range: start..<index))
            }
            runStart = nil
        }

        /// A quoted span, appended whole as `.quoted` and consumed through
        /// its closing quote.
        ///
        /// Single quotes honour NO escape in POSIX — every character up to
        /// the next `'` is literal, backslash included. Double quotes do
        /// honour one, so `"a\"b"` is a single span. A span that does not
        /// close on the line it opens is refused rather than followed: a
        /// multi-line quoted string is legal shell, this type simply
        /// declines to reason across the break.
        ///
        /// This is the ONE place the wide `looksLikeALineBreak` set is
        /// right, and it is right because the outcome is a refusal. `bash`
        /// would carry the span across a CR or a U+2028 happily; refusing
        /// there costs a legitimate command a nuisance, whereas the
        /// corresponding mistake in the other direction — deciding a
        /// construct ENDS at a scalar `bash` reads straight through — is
        /// what put a placeholder inside a `bash` comment while this type
        /// thought it was an argument.
        private mutating func readQuotedSpan(quoteScalar: Unicode.Scalar) -> Refusal? {
            let start = index
            advance()
            while index < scalars.endIndex {
                let scalar = scalars[index]
                if ShellScalar.looksLikeALineBreak(scalar) { return .unbalancedQuoting }
                if scalar == quoteScalar {
                    advance()
                    spans.append(Span(placement: .quoted, range: start..<index))
                    return nil
                }
                if quoteScalar == "\"" {
                    if scalar == "`" { return .commandSubstitution }
                    if scalar == "$" {
                        if let refusal = readExpansion() { return refusal }
                        continue
                    }
                    if scalar == "\\" {
                        let escaped = scalars.index(after: index)
                        guard escaped < scalars.endIndex else { return .unbalancedQuoting }
                        index = scalars.index(after: escaped)
                        continue
                    }
                }
                advance()
            }
            return .unbalancedQuoting
        }

        /// A `$…`. Only a plain `$NAME` or `$1` is read; everything else —
        /// `$(`, `$((`, `${`, `$'`, `$"`, a bare `$`, a `$` before anything
        /// non-ASCII — is refused. Accepting a plain variable costs nothing:
        /// it cannot contain a `{{NAME}}`, and no span is emitted for it, so
        /// a placeholder overlapping one is uncontained and therefore
        /// unsafe.
        private mutating func readExpansion() -> Refusal? {
            let next = scalars.index(after: index)
            guard next < scalars.endIndex else { return .expansion }
            let scalar = scalars[next]
            if scalar == "(" {
                let afterParenthesis = scalars.index(after: next)
                if afterParenthesis < scalars.endIndex, scalars[afterParenthesis] == "(" {
                    return .expansion
                }
                return .commandSubstitution
            }
            if scalar == "{" || scalar == "'" || scalar == "\"" { return .expansion }
            if ShellScalar.isASCIILetterOrUnderscore(scalar) {
                var scan = next
                while scan < scalars.endIndex,
                      ShellScalar.isASCIILetterOrUnderscore(scalars[scan])
                      || ShellScalar.isASCIIDigit(scalars[scan]) {
                    scan = scalars.index(after: scan)
                }
                index = scan
                return nil
            }
            if ShellScalar.isASCIIDigit(scalar) {
                index = scalars.index(after: next)
                return nil
            }
            return .expansion
        }
    }
}
