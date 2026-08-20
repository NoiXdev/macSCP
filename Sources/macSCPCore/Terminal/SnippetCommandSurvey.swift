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
        /// A command name that changes what the REST of the template means:
        /// it runs an argument as shell code at once (`eval`), on a later
        /// signal (`trap`), out of a file it names (`source`), or it
        /// installs what a later word will resolve to (`alias`, `hash -p`,
        /// `autoload`). After one of those, no reading of the remaining text
        /// can say which command a placeholder is an argument of, so the
        /// whole template is refused.
        ///
        /// A command whose re-parse is confined to its OWN arguments —
        /// `printf -v`, `test -v`, `exit`, `let` — is not this case. Those
        /// are surveyed normally and their arguments come out as
        /// `.reparsedArgument`, which refuses a placeholder among them
        /// without refusing the template it appears in.
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
        /// The same position, in a command whose NAME hands its own
        /// arguments back to the shell: `[ -f X ]`, `printf -v X`,
        /// `exit X`. The word stays one literal word and the shell
        /// evaluates it anyway, so a value here is code.
        ///
        /// It is a placement rather than a refusal because the damage is
        /// confined to this one command. The template around it is read as
        /// usual, which is the difference between refusing
        /// `[ -f {{PATH}} ]` and refusing every template that mentions `[`
        /// somewhere else on the line.
        case reparsedArgument
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
        /// A word standing after a redirection operator: the target
        /// itself, and every word behind it to the end of the command.
        /// Not an argument, and refused rather than reasoned about.
        ///
        /// It reaches past the target because of what a redirection does
        /// to the question "whose arguments am I reading". Between a
        /// command name and a placeholder, an operator is exactly where
        /// the plausible shells stop agreeing — bash's `{fd}>` puts the
        /// real command name AFTER it, and `&>` is a whole operator in
        /// bash, zsh and mksh while dash, posh, yash and ksh93u+ 2012 read
        /// its `&` as a background separator and start a new command at
        /// the `>`. Two rounds of this branch tried to model each shape
        /// and each time one spelling was modelled the wrong way round.
        /// So no word behind an operator is called an argument, whatever
        /// the operator turns out to have been.
        case afterRedirection
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
    /// From execution against the shells a server plausibly runs, and never
    /// from whichever binary happens to sit on the machine running the
    /// tests. Counted in the pass that wrote this list, there are eight of
    /// them: bash 3.2.57 (this Mac), bash 4.4 and bash 5.2.37 (containers),
    /// zsh 5.9, mksh R59, ksh93u+m 1.0.4, dash 0.5.12 and posh 0.14. Two
    /// more bash builds, 5.0 and 5.1, were asked for their NAMES only and
    /// added none.
    ///
    /// Each entry carries its own evidence: `.executed` names the shell and
    /// the shape that created the marker, `.sweptInert` means the whole
    /// option sweep ran in every one of those shells and left none,
    /// `.probedInert` means the shape a sweep cannot spell was tried by hand
    /// in every one of them and left none, and `.reasoned` is the honest
    /// label for a behaviour no shell here can be made to demonstrate — an
    /// interactive-only builtin, a module that would have to exist — where
    /// the reason, not a measurement, is the authority. A `.reasoned` entry
    /// is never a conclusion of "inert".
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
    /// The union is why mksh and ksh93 are on the list above. A review
    /// measured them and the posture lost: `ulimit {{X}}` was accepted here
    /// while mksh evaluates that count as arithmetic, and an array subscript
    /// inside mksh arithmetic expands a command substitution. Widening the
    /// shells widened the table's own vocabulary with it — `nameref` is
    /// mksh's and ksh93's alone, it is not a name bash or zsh has ever
    /// reported, and `nameref y='a[$(touch M)]'` creates the marker in mksh.
    /// A table scoped to bash and zsh does not contain that name at all, and
    /// a name the table does not contain is a name this reader accepts.
    ///
    /// ## What the refusal costs is scoped to ONE command
    ///
    /// A re-parsing name in command-name position used to refuse the whole
    /// template, wherever it stood. That was a larger price than the one
    /// that was agreed: `tar czf {{OUT}} /srv && printf 'done\n'` was
    /// refused over a `printf` the value never reaches, and so were
    /// `cd {{DIR}} && [ -d .git ] && git pull` and
    /// `rsync -a {{SRC}} /backup; exit 0`. What makes a value dangerous is
    /// the command it is an ARGUMENT of, and a value in a different command
    /// of the same line is not one of that command's arguments.
    ///
    /// So `Reach` splits the re-parsing names in two. `.itsOwnArguments` is
    /// the family whose re-parse is an assignment, a variable NAME or an
    /// arithmetic count — every one of those happens inside the command's
    /// own argument list and can install nothing that outlives it (a command
    /// substitution reached through a subscript runs in a subshell). Those
    /// commands are surveyed like any other and their arguments come out
    /// `.reparsedArgument`. `.theWholeTemplate` is everything else: a name
    /// that can run an arbitrary command (`eval`, `source`, a `mapfile -C`
    /// callback) or install what a later word resolves to (`alias`,
    /// `hash -p`, `autoload`, `zmodload`). After one of those the reader
    /// cannot say which command a later placeholder is an argument OF, so
    /// there is nothing left to narrow to and the template is refused whole.
    ///
    /// ## The command name alone is not the question
    ///
    /// The finding that produced this table was option-shaped: `-v` turns
    /// the FOLLOWING argument into a variable NAME, and bash evaluates an
    /// array subscript inside a name as arithmetic, which expands a command
    /// substitution. So the classification was decided by sweeping every
    /// name in the table against every single-letter option in both cases,
    /// in six argument positions — bare; after the option; after the option
    /// with a trailing word; before the option; attached to the option; and
    /// after the option's own argument — and with four payload shapes: a
    /// substitution, a subscript, an assignment through a subscript, and a
    /// bare command word for options that take a callback. What that sweep
    /// found beyond the names already refused:
    /// `-v` on `printf`, `test` and `[`, and zsh's own `print -v` (a name),
    /// `-C` and `-W` on `compgen` and
    /// `-C` on `mapfile`/`readarray` (a command), `-A` on zsh's `set`, `-a`
    /// on `zparseopts` and `zformat`, `-g` on `zstyle` (a name), and — the
    /// mechanism with the widest reach — zsh reading a builtin's NUMERIC
    /// argument as arithmetic, which fires `break`, `continue`, `return`,
    /// `shift`, `exit`, `logout` and `bye` — and which mksh applies to
    /// `ulimit` as well. Bracketed `[ … ]` and the second-argument name of
    /// `getopts` are shapes a flat sweep cannot spell, and were measured
    /// separately.
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
    /// asks every shell installed on the machine running the tests — `bash`
    /// through `compgen -b` and `-k`, `zsh` through `${(k)builtins}` and
    /// `${(k)reswords}`, `ksh` through `builtin` — and fails if any name
    /// they report is missing from this table, so a name macSCP has never
    /// seen still goes red. It cannot make a name safe: safety comes from
    /// an entry with evidence, written by a person who ran something, and
    /// on a shell a SERVER runs rather than this one.
    ///
    /// It is a lower bound with a KNOWN HOLE, and the hole has cost
    /// something. `builtin` lists ksh93's builtins and not its default
    /// ALIASES, and `redirect` is one of the aliases: `whence -v redirect`
    /// on macOS `/bin/ksh` answers "an alias for `command exec`", which
    /// puts the value in command-name position, and this table called it
    /// harmless for four rounds. Counted by asking `/bin/ksh -c alias`,
    /// ksh93u+ 2012 defines nineteen of them; seventeen are classified
    /// here, and the two that are not — `2d`, which expands to a function
    /// no shell defines and is inert in all eleven builds measured, and
    /// `nohup`, which is an external PROGRAM and therefore out of this
    /// table's scope by the standing decision below — are named here so
    /// the omission is a decision rather than an oversight. Extending the
    /// test to that source would drag every program of `nohup`'s shape in
    /// with it, and that is a scope question, not a defect.
    ///
    /// ## The boundary this table does NOT reach
    ///
    /// It is the set where the SHELL re-parses. It is emphatically not a
    /// list of every danger: a PROGRAM that interprets its own argument —
    /// `bash -c`, `sh -c`, `python -c`, `perl -e`, `awk`, `find -exec`,
    /// `xargs`, an `ssh` command string — reads a perfectly quoted word as
    /// code, and no quoting rule reaches inside it. Those are out of scope
    /// by standing decision.
    ///
    /// Two BUILTINS have that shape, counted by trying them: `jobs -x` and
    /// `hash -p`. Both are refused, and the second one is the reason the
    /// first is.
    ///
    /// `hash -p` was measured after a review found it in the accepted set:
    /// the argument it takes IS a path, which is what a `{{PATH}}`
    /// placeholder naturally holds, and the effect outlives the command —
    /// `hash -p ./ev.sh ls` makes every later `ls` in that session run
    /// `./ev.sh` (measured, bash 3.2.57 and 5.2.37). It does not re-read
    /// its own argument; it changes what a LATER command name means, which
    /// is the `.theWholeTemplate` reach.
    ///
    /// `jobs -x` was kept in the accepted set on the argument that
    /// `jobs -x 'touch M'` looks for a program called `touch M` and finds
    /// none. That sentence is true and it does not carry: a `{{PATH}}` or
    /// `{{SCRIPT}}` value is ONE word and one path, and
    /// `jobs -x './ev.sh'` runs it (measured, bash 3.2.57, 4.4 and 5.2.37).
    /// It is the same argument that moved `hash -p`, so it gets the same
    /// answer. The reach is `.theWholeTemplate` rather than
    /// `.itsOwnArguments` because of what `.itsOwnArguments` promises: that
    /// nothing installed by the re-parse can outlive the command. A program
    /// the value names can do anything, and "anything" is not confined to
    /// an argument list — so the narrow reach is not available here, whether
    /// or not the shell parses a second time. The cost is that a template
    /// naming `jobs` in command-name position is refused whole.
    ///
    /// An earlier version of this paragraph said "no accepted builtin now
    /// puts a value in command-name position" and called that a set of
    /// zero. It was not zero, and the sentence is worth keeping as a
    /// warning: it was written in the same pass as the `jobs` verdict, it
    /// sounded like a count, and nothing had been counted. `redirect` was
    /// in the set — a ksh93 default ALIAS for `command exec`, which no
    /// sweep of ksh's `builtin` output could ever surface. It is
    /// `.introducesACommandName` now.
    ///
    /// Swept afterwards, and this time the number is the measurement: the
    /// 46 names still carrying `.doesNotReparse`, less `suspend`, which
    /// cannot be swept because it SIGSTOPs the shell that runs it, in the
    /// three shapes `NAME 'V'`, `NAME -x 'V'` and `NAME -p 'V' zzz` with
    /// `V` the path of a script that creates a marker, across twelve shell
    /// builds — 1 656 executions, one marker, and it is `redirect`'s.
    /// `stop`, `type` and `times` are aliases of the same family and came
    /// out inert; `login` and `newgrp` were already refusing.
    /// How far one re-parsing name's danger reaches, and therefore how much
    /// of the template its presence refuses.
    ///
    /// The split is not a convenience. It is the difference between "this
    /// value is handed to a parser" and "somewhere on this line a word was
    /// redefined", and only the second can make a placeholder in a DIFFERENT
    /// command unsafe.
    enum Reach: Sendable, Equatable {
        /// The re-parse happens inside this command's own argument list: an
        /// assignment, a variable NAME, an arithmetic count. It cannot
        /// install anything that outlives the command — a command
        /// substitution reached through a subscript runs in a subshell — so
        /// a value in another command of the same template is untouched by
        /// it. Only this command's arguments are refused.
        case itsOwnArguments
        /// The name can run an arbitrary command, or make a later word
        /// resolve to something other than what it says: `eval`, `source`,
        /// `alias`, `hash -p`, `autoload`, a callback option that runs in
        /// the current shell. After one of these there is no honest answer
        /// to "which command is this placeholder an argument of", so the
        /// whole template is refused.
        case theWholeTemplate
    }

    enum Verdict: Sendable, Equatable {
        /// The shell itself turns an argument into shell code — at once, or
        /// on a later signal, or out of a file it names, or by reading a
        /// name or a number as something it evaluates. Refused, as far as
        /// the `Reach` says.
        ///
        /// The reach travels WITH the verdict rather than beside it so that
        /// a name which does not re-parse cannot be given one: there is no
        /// state in which `doesNotReparse` carries a reach, because the
        /// type does not allow writing it.
        case reparses(Reach)
        /// The word AFTER this one is what the shell runs, so the reader
        /// keeps expecting a command name. The strict direction: it makes
        /// the next word be checked instead of accepted.
        case introducesACommandName
        /// Reserved-word syntax this reader does not model at all. Refused
        /// rather than read on, because reading on is what turns "no rule
        /// for this" into acceptance.
        ///
        /// `function` is here by decision rather than by inability. Its
        /// body could be modelled — a `{` after `function NAME` opens a
        /// region where command names resume — but this reader models no
        /// other block, `f() { … }` is already refused because `(` is, and
        /// a reader that starts modelling ONE block is a reader that has to
        /// be right about where that block ends. The cost is stated where
        /// it falls: a snippet that DEFINES a function cannot carry a
        /// placeholder anywhere in it, in either spelling.
        case unmodelledSyntax
        /// A reserved word that takes a WORD rather than a command name.
        /// Read as an ordinary command, which is what it behaves like here.
        ///
        /// The condition on that "here" is load-bearing, and `function`
        /// used to be in this set while breaking it: the word it takes is
        /// followed by a `{` that opens a BODY, and a body is full of
        /// command names. Reading it as an ordinary command left
        /// `expectsCommandName` false across the whole body, so
        /// `function f { printf -v {{X}} '%s' y; }; f` was accepted with
        /// its `printf` never compared against anything. A reserved word
        /// belongs here only while nothing between it and the next
        /// separator is a command name; where a command name follows, the
        /// verdict is `.unmodelledSyntax`.
        case takesAWordNotACommandName
        /// Measured not to turn an argument into shell code.
        case doesNotReparse
    }

    /// Where an entry's verdict comes from. The distinction is the point of
    /// the table: a shell that could not be made to show a behaviour is not
    /// a shell that showed the behaviour absent.
    enum Evidence: Sendable, Equatable {
        /// A marker was created. The string names the shell and the shape.
        /// It is therefore only ever the evidence of a REFUSING verdict, and
        /// `nothingIsCalledHarmlessOnAReason` fails a table that puts it on
        /// an accepted one — six reserved words carried it while their own
        /// strings said "no marker", which is what `.probedInert` is for.
        case executed(String)
        /// The option sweep ran in every listed shell and produced none.
        case sweptInert
        /// A shape the flat sweep cannot spell — a reserved word, which
        /// takes a syntax rather than an argument list — was tried by hand
        /// in every listed shell and produced no marker. The string names
        /// the shape that was tried.
        case probedInert(String)
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

    /// The checked-in classification. Its scope is the union of the
    /// builtins and reserved words of every shell this project has measured
    /// — counted here, eight: bash 3.2.57, bash 4.4, bash 5.2.37, zsh 5.9,
    /// mksh R59, ksh93u+m 1.0.4, dash 0.5.12 and posh 0.14 — and a name
    /// only ONE of them has still belongs here, because the shell on the
    /// other end may be that one. `nameref`, `hist`, `alarm`, `compound`,
    /// `enum`, `login`, `newgrp`, `realpath`, `rename`, `redirect`,
    /// `sleep`, `stop`, `vmap` and `vpath` are in the list for exactly that
    /// reason: neither bash nor zsh has ever reported one of them, and
    /// `nameref y='a[$(touch M)]'` creates the marker in mksh. Anyone
    /// adding a fifteenth name reads this sentence first, so it says the
    /// scope the entries below actually have.
    static let shellVocabulary: [Fact] = [
        Fact("eval", .reparses(.theWholeTemplate), .executed("every shell: eval '$(touch M)'")),
        Fact("command", .reparses(.theWholeTemplate),
             .executed("every shell but zsh: command eval 'touch M'")),
        Fact("builtin", .reparses(.theWholeTemplate),
             .executed("bash, zsh, mksh, posh: builtin eval 'touch M'")),
        Fact("source", .reparses(.theWholeTemplate),
             .executed("bash, zsh, mksh, ksh93: source ./f.sh, a file holding touch M")),
        Fact(".", .reparses(.theWholeTemplate),
             .executed("every shell: . ./f.sh, a file holding touch M")),
        Fact("trap", .reparses(.theWholeTemplate), .executed("every shell: trap 'touch M' EXIT")),
        Fact("alias", .reparses(.theWholeTemplate),
             .executed("mksh, ksh93, dash: alias a='touch M', then a; bash wants expand_aliases")),
        Fact("emulate", .reparses(.theWholeTemplate),
             .executed("zsh 5.9: emulate zsh -c 'touch M'")),
        Fact("hash", .reparses(.theWholeTemplate),
             .executed("bash 3.2/4.4/5.2: hash -p ./ev.sh zzz, then zzz runs it; zsh: hash zzz=")),
        Fact("jobs", .reparses(.theWholeTemplate),
             .executed("bash 3.2/4.4/5.2: jobs -x ./ev.sh runs the program the value names")),
        Fact("compgen", .reparses(.theWholeTemplate),
             .executed("every bash: compgen -C 'touch M' / -W '$(touch M)'")),
        Fact("mapfile", .reparses(.theWholeTemplate),
             .executed("bash 4.4/5.2: mapfile -C 'touch M' -c 1 arr")),
        Fact("readarray", .reparses(.theWholeTemplate),
             .executed("bash 4.4/5.2: readarray -C 'touch M' -c 1 arr")),
        Fact("bind", .reparses(.theWholeTemplate),
             .reasoned("binds a key to a command line an interactive shell later runs")),
        Fact("bindkey", .reparses(.theWholeTemplate),
             .reasoned("zsh's bind; -s pushes its argument back as input")),
        Fact("complete", .reparses(.theWholeTemplate),
             .reasoned("-C names a command run to produce completions")),
        Fact("compctl", .reparses(.theWholeTemplate),
             .reasoned("zsh's complete; -K names a function run to complete")),
        Fact("fc", .reparses(.theWholeTemplate),
             .reasoned("-s re-runs a history entry with substitutions applied")),
        Fact("r", .reparses(.theWholeTemplate), .reasoned("zsh's fc -s under a shorter name")),
        Fact("hist", .reparses(.theWholeTemplate),
             .reasoned("ksh93's fc, and -s re-runs a history entry the same way")),
        Fact("history", .reparses(.theWholeTemplate),
             .reasoned("-s pushes a line into the history an interactive shell re-runs")),
        Fact("enable", .reparses(.theWholeTemplate),
             .reasoned("-f loads a builtin out of a shared object")),
        Fact("zmodload", .reparses(.theWholeTemplate),
             .reasoned("zsh's enable -f; loads a module and can alias parameters")),
        Fact("zcompile", .reparses(.theWholeTemplate),
             .reasoned("compiles shell code into a file the shell later reads")),
        Fact("autoload", .reparses(.theWholeTemplate),
             .reasoned("marks a name the shell later loads as code out of fpath")),
        Fact("functions", .reparses(.theWholeTemplate),
             .reasoned("-M defines a math function the shell calls from arithmetic")),
        Fact("sched", .reparses(.theWholeTemplate),
             .reasoned("stores a command line the shell runs at a later prompt")),
        Fact("alarm", .reparses(.theWholeTemplate),
             .reasoned("ksh93's sched: it stores an action the shell runs when the alarm fires")),
        Fact("zle", .reparses(.theWholeTemplate),
             .reasoned("-N names a widget function the line editor later runs")),
        Fact("zregexparse", .reparses(.theWholeTemplate),
             .executed("zsh 5.9: zregexparse 'a[$(touch M)]' b c")),
        Fact("compadd", .reparses(.theWholeTemplate),
             .reasoned("a completion-widget builtin: names parameters it assigns through")),
        Fact("comparguments", .reparses(.theWholeTemplate),
             .reasoned("a completion-widget builtin: names parameters it assigns through")),
        Fact("compcall", .reparses(.theWholeTemplate),
             .reasoned("a completion-widget builtin: names parameters it assigns through")),
        Fact("compdescribe", .reparses(.theWholeTemplate),
             .reasoned("a completion-widget builtin: names parameters it assigns through")),
        Fact("compfiles", .reparses(.theWholeTemplate),
             .reasoned("a completion-widget builtin: names parameters it assigns through")),
        Fact("compgroups", .reparses(.theWholeTemplate),
             .reasoned("a completion-widget builtin: names parameters it assigns through")),
        Fact("compquote", .reparses(.theWholeTemplate),
             .reasoned("a completion-widget builtin: names parameters it assigns through")),
        Fact("compset", .reparses(.theWholeTemplate),
             .reasoned("a completion-widget builtin: names parameters it assigns through")),
        Fact("comptags", .reparses(.theWholeTemplate),
             .reasoned("a completion-widget builtin: names parameters it assigns through")),
        Fact("comptry", .reparses(.theWholeTemplate),
             .reasoned("a completion-widget builtin: names parameters it assigns through")),
        Fact("compvalues", .reparses(.theWholeTemplate),
             .reasoned("a completion-widget builtin: names parameters it assigns through")),
        Fact("let", .reparses(.itsOwnArguments),
             .executed("bash 3.2/4.4/5.2, mksh: let 'a[$(touch M)]'; zsh wants the assignment")),
        Fact("declare", .reparses(.itsOwnArguments),
             .executed("bash 3.2/4.4/5.2, zsh 5.9: declare 'x[$(touch M)]=1'")),
        Fact("typeset", .reparses(.itsOwnArguments),
             .executed("bash, zsh, mksh: typeset 'x[$(touch M)]=1'")),
        Fact("local", .reparses(.itsOwnArguments),
             .executed("bash, mksh, posh, in a function: local 'x[$(touch M)]=1'")),
        Fact("unset", .reparses(.itsOwnArguments),
             .executed("bash, zsh, mksh, with an array set: unset 'a[$(touch M)]'")),
        Fact("export", .reparses(.itsOwnArguments),
             .executed("zsh 5.9, mksh, posh: export 'a[$(touch M)]'")),
        Fact("private", .reparses(.itsOwnArguments),
             .executed("zsh 5.9: private 'a[$(touch M)]'")),
        Fact("readonly", .reparses(.itsOwnArguments),
             .executed("mksh R59, posh 0.14: readonly 'a[$(touch M)]'")),
        Fact("nameref", .reparses(.itsOwnArguments),
             .executed("mksh R59: a=1; nameref y='a[$(touch M)]'; y=2")),
        Fact("compound", .reparses(.itsOwnArguments),
             .reasoned("ksh93 spells it typeset -C, and typeset fires in bash, zsh and mksh")),
        Fact("enum", .reparses(.itsOwnArguments),
             .reasoned("a ksh93 declaration builtin, and it makes its type name one as well")),
        Fact("read", .reparses(.itsOwnArguments),
             .executed("bash, zsh, mksh, posh: read 'a[$(touch M)]'")),
        Fact("getln", .reparses(.itsOwnArguments),
             .executed("zsh 5.9: getln 'a[$(touch M)]'")),
        Fact("getopts", .reparses(.itsOwnArguments),
             .executed("mksh, posh: getopts ab 'a[$(touch M)]'; zsh once there is an option")),
        Fact("set", .reparses(.itsOwnArguments), .executed("zsh 5.9: set -A 'a[$(touch M)]' x")),
        Fact("printf", .reparses(.itsOwnArguments),
             .executed("bash 4.4/5.2, zsh 5.9: printf -v 'a[$(touch M)]' '%s' y")),
        Fact("print", .reparses(.itsOwnArguments),
             .executed("zsh 5.9: print -v 'a[$(touch M)]' y")),
        Fact("test", .reparses(.itsOwnArguments),
             .executed("bash 4.4/5.2, mksh: test -v 'a[$(touch M)]'")),
        Fact("[", .reparses(.itsOwnArguments),
             .executed("bash 4.4/5.2, mksh: [ -v 'a[$(touch M)]' ]")),
        Fact("zstyle", .reparses(.itsOwnArguments),
             .executed("zsh 5.9: zstyle -g 'a[$(touch M)]'")),
        Fact("zformat", .reparses(.itsOwnArguments),
             .executed("zsh 5.9: zformat -a 'a[$(touch M)]' x y")),
        Fact("zparseopts", .reparses(.itsOwnArguments),
             .executed("zsh 5.9: set -- -x; zparseopts -a 'a[$(touch M)]' x")),
        Fact("break", .reparses(.itsOwnArguments),
             .executed("zsh 5.9: break 'x[$(touch M)]=1' — the count is arithmetic")),
        Fact("continue", .reparses(.itsOwnArguments),
             .executed("zsh 5.9: continue 'x[$(touch M)]=1' — likewise")),
        Fact("return", .reparses(.itsOwnArguments),
             .executed("zsh 5.9: return 'x[$(touch M)]=1' — likewise")),
        Fact("shift", .reparses(.itsOwnArguments),
             .executed("zsh 5.9, mksh, posh, ksh93u+: shift 'x[$(touch M)]=1' — likewise")),
        Fact("exit", .reparses(.itsOwnArguments),
             .executed("zsh 5.9: exit 'x[$(touch M)]=1' — likewise")),
        Fact("logout", .reparses(.itsOwnArguments),
             .executed("zsh 5.9: logout 'x[$(touch M)]=1' — likewise")),
        Fact("bye", .reparses(.itsOwnArguments),
             .executed("zsh 5.9: bye 'x[$(touch M)]=1' — likewise")),
        Fact("ulimit", .reparses(.itsOwnArguments),
             .executed("mksh R59, ksh93u+: ulimit 'a[$(touch M)]' — the count is arithmetic")),
        Fact("vared", .reparses(.itsOwnArguments),
             .reasoned("edits a named parameter, the shape read is measured on")),
        Fact("float", .reparses(.itsOwnArguments),
             .reasoned("a typeset variant, and typeset is measured")),
        Fact("integer", .reparses(.itsOwnArguments),
             .executed("mksh R59: integer 'x[$(touch M)]=1'")),
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
        Fact("login", .introducesACommandName,
             .reasoned("ksh93 replaces the shell with the program that follows")),
        Fact("newgrp", .introducesACommandName, .reasoned("ksh93's login under another name")),
        Fact("redirect", .introducesACommandName,
             .executed("ksh93u+ 2012 (macOS /bin/ksh): an alias for `command exec`, "
                 + "so redirect './ev.sh' runs the program the value names")),
        Fact("-", .introducesACommandName,
             .reasoned("zsh runs the following command name as a login shell")),
        Fact("[[", .unmodelledSyntax,
             .executed("bash 3.2/4.4/5.2, mksh: [[ 1 -eq 'a[$(touch M)]' ]]")),
        Fact("]]", .unmodelledSyntax,
             .reasoned("a reader that refuses the opener cannot claim to know the closer")),
        Fact("repeat", .unmodelledSyntax,
             .executed("zsh 5.9: repeat 'x[$(touch M)]=1' echo hi — the count is arithmetic")),
        Fact("case", .takesAWordNotACommandName,
             .probedInert("case 'a[$(touch M)]' in *) ;; esac")),
        Fact("in", .takesAWordNotACommandName, .probedInert("for v in 'a[$(touch M)]'")),
        Fact("for", .takesAWordNotACommandName,
             .probedInert("for 'a[$(touch M)]' in x — a syntax error wherever it was tried")),
        Fact("select", .takesAWordNotACommandName,
             .probedInert("select 'a[$(touch M)]' in x; do break; done")),
        Fact("function", .unmodelledSyntax,
             .executed("bash 3.2/5.2, zsh, ksh93: function f { eval 'touch M'; }; f")),
        Fact("foreach", .takesAWordNotACommandName,
             .probedInert("zsh's for: foreach 'a[$(touch M)]' (x) … end")),
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
        Fact("help", .doesNotReparse, .sweptInert),
        Fact("kill", .doesNotReparse, .sweptInert),
        Fact("limit", .doesNotReparse, .sweptInert),
        Fact("log", .doesNotReparse, .sweptInert),
        Fact("popd", .doesNotReparse, .sweptInert),
        Fact("pushd", .doesNotReparse, .sweptInert),
        Fact("pushln", .doesNotReparse, .sweptInert),
        Fact("pwd", .doesNotReparse, .sweptInert),
        Fact("realpath", .doesNotReparse, .sweptInert),
        Fact("rehash", .doesNotReparse, .sweptInert),
        Fact("rename", .doesNotReparse, .sweptInert),
        Fact("setopt", .doesNotReparse, .sweptInert),
        Fact("shopt", .doesNotReparse, .sweptInert),
        Fact("sleep", .doesNotReparse, .sweptInert),
        Fact("stop", .doesNotReparse, .sweptInert),
        Fact("suspend", .doesNotReparse, .sweptInert),
        Fact("times", .doesNotReparse, .sweptInert),
        Fact("true", .doesNotReparse, .sweptInert),
        Fact("ttyctl", .doesNotReparse, .sweptInert),
        Fact("type", .doesNotReparse, .sweptInert),
        Fact("umask", .doesNotReparse, .sweptInert),
        Fact("unalias", .doesNotReparse, .sweptInert),
        Fact("unfunction", .doesNotReparse, .sweptInert),
        Fact("unhash", .doesNotReparse, .sweptInert),
        Fact("unlimit", .doesNotReparse, .sweptInert),
        Fact("unsetopt", .doesNotReparse, .sweptInert),
        Fact("vmap", .doesNotReparse, .sweptInert),
        Fact("vpath", .doesNotReparse, .sweptInert),
        Fact("wait", .doesNotReparse, .sweptInert),
        Fact("whence", .doesNotReparse, .sweptInert),
        Fact("where", .doesNotReparse, .sweptInert),
        Fact("which", .doesNotReparse, .sweptInert),
    ]

    /// Command names where the shell turns an argument into shell code,
    /// whatever the reach. Derived from `shellVocabulary` so the table is
    /// the only place a verdict is written down.
    static let reparsingCommands: Set<String> = Set(
        shellVocabulary.lazy.filter { if case .reparses = $0.verdict { true } else { false } }
            .map(\.name))

    /// The subset of those whose reach is `.theWholeTemplate` — the names
    /// after which no later position can be called safe, because what a
    /// later word RUNS is no longer what it says. A subset by construction,
    /// which is what keeps "refuse everything" and "refuse this command's
    /// arguments" from becoming two independent lists that disagree.
    static let templateWideReparsingCommands: Set<String> = Set(
        shellVocabulary.lazy
            .filter { $0.verdict == .reparses(.theWholeTemplate) }
            .map(\.name))

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
        /// True immediately after a redirection operator, for the ONE word
        /// that is its target. It has to beat `expectsCommandName`: in
        /// `>f eval {{X}}` the `f` is the target and `eval` is still the
        /// command name, and a reader that let `f` be the name would hand
        /// `eval` on as an ordinary argument.
        var expectsRedirectionTarget = false
        /// True from a redirection operator to the end of that command.
        ///
        /// Unlike `expectsRedirectionTarget` this one does not stop at the
        /// target, and it deliberately does NOT stop at a command name
        /// either. It is the answer to a class of finding rather than to a
        /// shape: where the plausible shells disagree about an operator,
        /// they disagree about WHICH COMMAND the words behind it belong to,
        /// and every version of this reader that picked one reading was
        /// wrong for some measured shell. `declare &>f x {{X}}` is the case
        /// that makes the "not at a command name" part load-bearing — dash
        /// reads `x` as a command name and `{{X}}` as its argument, bash
        /// reads both as arguments of `declare`, and
        /// `declare &>f x 'x[$(touch M)]=1'` creates the marker in bash
        /// 3.2.57, 4.4, 5.0 and 5.2.37 and in zsh 5.9.
        var sawRedirection = false
        /// True between a command NAME that re-parses its own arguments and
        /// the end of that command.
        ///
        /// "The end of that command" is not a second notion of where a
        /// command starts: it is `beginCommand`, which is what already
        /// answers that question for `expectsCommandName`. Counted in the
        /// pass that wrote this sentence, `read()` calls it from three
        /// branches: a line feed, a `;` or a `)`, and a `&` or a `|`.
        /// The `&&` and `||` spellings arrive as two
        /// `&` or two `|` and reset twice, which is the same answer said
        /// twice. `if`, `then`, `while`, `do` and the other introducers do
        /// NOT reset it, and must not: they leave the command name still to
        /// come, so the flag is false there anyway, and the word that
        /// follows sets it for itself.
        ///
        /// What actually carries this flag is the ASSIGNMENT at every
        /// command name, not the reset in `beginCommand`: no word is ever
        /// classified as an argument before a command name of the same
        /// command has been read, so the reset is unreachable as a second
        /// line of defence. Measured, and stated here rather than implied —
        /// deleting it leaves the whole suite green, so it is belt and
        /// braces with no test of its own, and a reader looking for the
        /// guarantee should look at the assignment.
        var commandReparsesItsArguments = false

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
                if scalar == ";" || scalar == ")" {
                    advance()
                    beginCommand()
                    continue
                }
                // A `&` or a `|` ends a simple command, and a `&` does so
                // even when a `>` follows it.
                //
                // `&>` was read here as one operator for exactly one round.
                // Measured on the eight shells this project's table is
                // scoped to plus ksh93u+ 2012 and yash, `&>` is an operator
                // in bash 3.2.57, bash 4.4, bash 5.0, bash 5.2.37, zsh 5.9,
                // mksh R59 and ksh93u+m 1.0.4, and NOT one in dash 0.5.12,
                // posh 0.14, yash and macOS `/bin/ksh` — there the `&` is
                // the background separator, `>out.log` opens a new command,
                // and `ls &>out.log './ev.sh'` runs the script the value
                // names. Every other operator form this reader knows is an
                // operator in all of them; `&>` and `&>>` are the only two
                // the shells split on.
                //
                // Where they split, this reader takes the reading that
                // refuses more, and given `sawRedirection` the separator
                // reading is that reading in both directions: it keeps
                // `>out.log` a redirection, so nothing behind it is an
                // argument either way, AND it puts the next word in
                // command-name position, where `eval`, `alias` and the rest
                // of the table are looked up. The operator reading looked
                // them up nowhere: `ls &>f eval {{X}}` came out ACCEPTED
                // under it, and `ls &>f eval 'touch MARKER'` creates the
                // marker in dash 0.5.12, posh, yash and ksh93u+ 2012.
                if scalar == "&" || scalar == "|" {
                    advance()
                    beginCommand()
                    continue
                }
                if scalar == "(" || scalar == "`" {
                    return .refused(.commandSubstitution)
                }
                if scalar == "<" || scalar == ">" {
                    if let refusal = readRedirectionOperator() {
                        return .refused(refusal)
                    }
                    continue
                }
                // `2>&1`, `1>&2`, `0<&-`: a run of digits at a word boundary
                // that runs straight into a `<` or a `>` is a FILE
                // DESCRIPTOR, not a word — measured, `echo 12>f` prints to
                // fd 12 and leaves `f` empty. Reaching this only from the
                // top of the loop is what makes it right: every path back
                // here is a word boundary, so `echo a2>f` still reads `a2`
                // as a word and redirects fd 1.
                if ShellScalar.isASCIIDigit(scalar), let start = redirectionAfterFileDescriptor() {
                    index = start
                    if let refusal = readRedirectionOperator() {
                        return .refused(refusal)
                    }
                    continue
                }
                // `{fd}>f cmd …`: bash from 4.1 and ksh93 read `{NAME}`
                // running straight into a `<` or a `>` as a
                // DESCRIPTOR-VARIABLE assignment, which means the command
                // name is the word BEHIND the redirection. This reader took
                // `{fd}` for the name and never looked the real one up —
                // the same hole the digit spelling had, one spelling over:
                // `{fd}>f eval 'touch MARKER'` creates the marker in
                // bash 4.4, 5.0 and 5.2.37 and in both ksh93 builds.
                //
                // Refused rather than consumed like the digit prefix,
                // because `{` also opens a group command (`{ echo x; }`)
                // and telling the two apart is one more lexical role in the
                // reader that has produced this branch's last two critical
                // findings. Consuming it would buy nothing anyway:
                // `sawRedirection` refuses a placeholder behind the
                // operator either way.
                if scalar == "{", opensDescriptorVariable() {
                    return .refused(.unrecognizedSyntax)
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
            sawRedirection = false
            commandReparsesItsArguments = false
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

        /// Where the redirection operator starts when `index` is on the
        /// first digit of a file-descriptor prefix, or `nil` when the digits
        /// are an ordinary word. Only the digits are skipped; the operator
        /// itself is left for `readRedirectionOperator`.
        private func redirectionAfterFileDescriptor() -> String.Index? {
            var scan = index
            while scan < scalars.endIndex, ShellScalar.isASCIIDigit(scalars[scan]) {
                scan = scalars.index(after: scan)
            }
            guard scan < scalars.endIndex, scalars[scan] == "<" || scalars[scan] == ">"
            else { return nil }
            return scan
        }

        /// Whether `index` sits on the `{` of a `{NAME}` that runs straight
        /// into a `<` or a `>` — bash's and ksh93's descriptor-variable
        /// spelling of a file-descriptor prefix. `NAME` is the identifier
        /// those shells accept there, and nothing else: `{ echo x; }` has a
        /// blank after the brace and `{1}>f` has no identifier, so neither
        /// is one.
        ///
        /// Only ever asked from the top of `read()`, which is a word
        /// boundary — the same condition that makes the digit prefix right.
        private func opensDescriptorVariable() -> Bool {
            var scan = scalars.index(after: index)
            guard scan < scalars.endIndex, ShellScalar.isASCIILetterOrUnderscore(scalars[scan])
            else { return false }
            while scan < scalars.endIndex,
                  ShellScalar.isASCIILetterOrUnderscore(scalars[scan])
                  || ShellScalar.isASCIIDigit(scalars[scan]) {
                scan = scalars.index(after: scan)
            }
            guard scan < scalars.endIndex, scalars[scan] == "}" else { return false }
            scan = scalars.index(after: scan)
            return scan < scalars.endIndex && (scalars[scan] == "<" || scalars[scan] == ">")
        }

        /// ONE redirection operator, read as a unit.
        ///
        /// It is a unit because the pieces it is made of are the pieces a
        /// shell ends a command with. `readRedirectionOperator` used to read
        /// only the `<` or `>` (plus a second `>`) and hand the rest back to
        /// the loop, so the `&` of `2>&1` and the `|` of `>|f` fell into the
        /// separator branch: `beginCommand` ran where no command began, the
        /// re-parsing flag was cleared, the descriptor word was read as a
        /// command NAME, and the placeholder behind it came out an ordinary
        /// argument of a command that does not exist. Measured on that
        /// reading, `declare 2>&1 {{X}}` was accepted and created the marker
        /// in bash 3.2.57, 4.4 and 5.2.37 and in zsh 5.9.
        ///
        /// So every `&` and `|` that belongs to an operator is consumed
        /// HERE, and the shapes are enumerated rather than pattern-guessed.
        /// Counted while writing this list, there are seven: `>`, `>>` and
        /// `<`; the read-write `<>`; the descriptor duplications `>&` and
        /// `<&`; and the clobbering `>|`. Every one of the seven opens with
        /// a `<` or a `>`, so every one of them is also reached with a
        /// file-descriptor digit run already consumed by the caller, which
        /// is what `2>&1`, `1>&2` and `0<&-` are. What follows a
        /// duplication — the `-` of `>&-`, the `m` of `n>&m` — is read as an
        /// ordinary word, and a word after a redirection is
        /// `.afterRedirection`, never an argument.
        ///
        /// `&>` and `&>>` were an eighth and a ninth form for one round and
        /// are not forms here at all any more: the shells split on them, and
        /// `read()` says at its `&` branch which way the split went and why
        /// the separator reading is the refusing one. What reaches this
        /// method from a `&>` is the bare `>` behind a command boundary.
        ///
        /// Everything else FAILS CLOSED. A `&` or a `|` still standing
        /// after the operator has been read is a shape this reader does not
        /// know — zsh's `>>&`, `>&|`, `&>|` and `&>>|` among them — and it
        /// is refused as `.unrecognizedSyntax` rather than handed back to
        /// the loop, because handing it back is precisely how it would
        /// become a separator again. Over-refusing an operator costs a
        /// snippet nobody has written yet; the other direction cost this
        /// branch a critical finding.
        ///
        /// `<<` in any of its forms is a here-document, and is read here in
        /// the unquoted state, so a `<<` inside a string or a comment never
        /// reaches this branch. A `(` after the operator needs no case of
        /// its own: it is left for the loop, which refuses every `(` as
        /// `.commandSubstitution`.
        private mutating func readRedirectionOperator() -> Refusal? {
            let openerScalar = scalars[index]
            advance()
            if openerScalar == "<" {
                if index < scalars.endIndex, scalars[index] == "<" { return .heredoc }
                if index < scalars.endIndex, scalars[index] == "&" || scalars[index] == ">" {
                    advance()
                }
            } else if index < scalars.endIndex {
                if scalars[index] == ">" {
                    advance()
                } else if scalars[index] == "&" || scalars[index] == "|" {
                    advance()
                }
            }
            if index < scalars.endIndex, scalars[index] == "&" || scalars[index] == "|" {
                return .unrecognizedSyntax
            }
            expectsRedirectionTarget = true
            sawRedirection = true
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
            // The order is the rule. `expectsRedirectionTarget` beats the
            // command name so that `f` in `>f eval {{X}}` is a target and
            // `eval` is still the name; `expectsCommandName` beats
            // `sawRedirection` for the same reason, one word further on —
            // reading `eval` there as "just something behind a redirection"
            // would refuse the placeholder but skip the lookup that refuses
            // the TEMPLATE, and `>f alias x=eval; x {{X}}` needs the lookup.
            // `sawRedirection` comes last: an argument behind an operator is
            // still an argument of a re-parsing command when there is one,
            // and `.reparsedArgument` says which command that was.
            let placement: Placement =
                expectsRedirectionTarget ? .afterRedirection
                : expectsCommandName ? .commandName
                : commandReparsesItsArguments ? .reparsedArgument
                : sawRedirection ? .afterRedirection : .argument
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
                    // ASSIGNED on every command name, not set on the
                    // re-parsing ones: the false branch is what stops the
                    // flag from outliving the command it was set for
                    // without depending on `beginCommand` having run in
                    // between. `beginCommand` clears it too, and the two
                    // agreeing costs nothing.
                    commandReparsesItsArguments =
                        word.isOneOf(SnippetCommandSurvey.reparsingCommands)
                    // A name whose reach is the whole template refuses
                    // here and now: after `eval`, `alias` or `hash -p`,
                    // what a later word RUNS is no longer what it says, so
                    // there is no later command to narrow the refusal to.
                    if word.isOneOf(SnippetCommandSurvey.templateWideReparsingCommands) {
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
