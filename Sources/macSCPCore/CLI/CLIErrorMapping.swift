import Foundation

/// What `macscp-cli diagnose` refuses before it measures anything.
///
/// An error type rather than ArgumentParser's own `ValidationError`, and
/// that is the whole reason it exists: a `ValidationError` is thrown during
/// the PARSE, lands in the CLI `main()`'s outer catch, and exits with
/// ArgumentParser's own 64 — while the design fixes exit `2` for this
/// refusal (`docs/superpowers/specs/2026-09-04-cli-diagnose-design.md`,
/// "Exit codes"). Thrown from `run()` instead, it goes through
/// `CLIErrorMapping` below like every other error a subcommand raises, and
/// `CLIExitCode.usage` is what comes out.
///
/// The ARGUMENT SHAPE — no target at all, or both a session and a `--host`
/// — is still a `ValidationError` in the command itself, exiting 64 the way
/// a missing argument does on every other subcommand. This case is not a
/// shape problem: the arguments parse, and what is wrong is that the scope
/// asks for a measurement the target cannot supply.
///
/// In Core, not the CLI target, for this file's own reason: the CLI has no
/// test target.
public enum DiagnoseUsageError: Error, Equatable, Sendable {
    /// `--host` with a scope whose steps need a stored session — the dial,
    /// the contributions and the throughput test all authenticate, and a
    /// bare endpoint carries
    /// no session id for a secret source to answer for. Refused up front
    /// rather than reported as a `skipped` row nobody asked for.
    case scopeNeedsASession(DiagnosticScope)

    /// The refusal a `--host` form earns for `scope`, or `nil` for a scope
    /// it may run.
    ///
    /// `complete` is on the permitted side even though it RUNS the dial and
    /// the contributions: it also runs the resolve, the TCP connection, the
    /// echo and the trace, so the walk measures plenty and the two
    /// authenticating steps report `skipped` beside the rest. The three
    /// refused scopes are the ones whose ONLY steps beyond the resolve
    /// authenticate — asked without a session, they produce a row saying
    /// nothing was measured and nothing else.
    ///
    /// `internet` is on the permitted side for a different reason from the
    /// other three there, and the difference matters: it is not that a bare
    /// endpoint can run it, but that it runs against NO target at all. The
    /// command refuses a session and a `--host` for it in
    /// `DiagnoseCommand.validate()`, as a `ValidationError` exiting 64,
    /// before this function is ever asked about it. Answering
    /// `scopeNeedsASession` here would be the opposite of true.
    ///
    /// An exhaustive switch, so a new `DiagnosticScope` cannot reach the CLI
    /// until someone decides which side of this it is on — as the sixth,
    /// `throughput`, was decided on 2026-09-19, and the seventh,
    /// `internet`, on 2026-09-20.
    public static func refusal(forEndpointScope scope: DiagnosticScope) -> DiagnoseUsageError? {
        switch scope {
        case .dial, .contributions, .throughput: return .scopeNeedsASession(scope)
        case .complete, .ping, .trace, .internet: return nil
        }
    }
}

/// Maps a thrown error to the process exit code AND a human-readable stderr
/// message. Lives in Core, not the CLI target (M20 Task 10): the CLI has no
/// test target, so this — the actual decision logic ArgumentParser's default
/// error handling otherwise collapses to a flat exit code 1 — needs to live
/// somewhere it can be pinned by a test (the pattern `CLISecretSources.swift`
/// established in Task 8). Pure lookup, no I/O.
///
/// NOT responsible for ArgumentParser's OWN errors (help requests, usage
/// validation, unknown flags): those never reach here — the CLI's `main()`
/// override only routes errors thrown by a subcommand's `run()` through this
/// mapping, leaving parse-time errors to ArgumentParser's default handling.
public enum CLIErrorMapping {
    public static func exitCode(for error: Error) -> CLIExitCode {
        switch error {
        case is TransferSourceError:
            return .usage
        case is DeleteSourceError:
            return .usage
        case let error as TransferPlanError:
            switch error {
            case .conflict: return .conflict
            // A malformed argument, not a real destination collision — see
            // the case's own doc comment (M20 Task 10 fix).
            case .emptyDestinationDirectory: return .usage
            }
        case is SessionReferenceError:
            return .usage
        case is DiagnoseUsageError:
            return .usage
        case let error as HostKeyError:
            switch error {
            case .mismatch: return .hostKeyMismatch
            case .rejectedByUser: return .hostKeyUnknown
            }
        case is StoredSessionConnectionError, is PasswordCommandError, is KeychainError:
            return .auth
        // Named rather than left to the `default` arm, with the code that arm
        // gives: an unreadable `sessions-v2.json` reaches the CLI as the
        // decoder's own error and exits through `default`, and the two store
        // failures exit alike. `CLIErrorMappingTests
        // .anUnreadableForwardingStoreExitsLikeAnUnreadableSessionStore`
        // reads that code off the real session-store error.
        case is TunnelStoreError:
            return .connection
        // The key store on this machine could not be read (review
        // follow-ups of 2026-09-18, Task 6): a store that could not be used,
        // which `CLIExitCode.connection` covers — and the code the same
        // failure exited with through `default` while it still read as a
        // missing passphrase, so no script's branch moves.
        case SSHKeyError.managedKeyStoreUnreadable:
            return .connection
        // The server accepted the connection and the login, then did not
        // start the SFTP subsystem asked of it — a remote-side refusal.
        case let error as SFTPStartError:
            switch error {
            case .noResponse: return .remote
            }
        case let error as RemoteFSError:
            switch error {
            case .authenticationFailed, .jumpAuthenticationFailed:
                return .auth
            case .connectionFailed:
                return .connection
            case .notFound, .permissionDenied, .protocolError:
                return .remote
            // Both are S3 bucket-list outcomes, reachable from a connection
            // with `startsAtBucketList` on. This used to add "which no
            // stored session can carry yet" — true when the arms were
            // written, false since `f325ce3` put the field on
            // `StoredS3Config`, and the CLI connects stored sessions for
            // every backend through `SessionConnecting.connect`. So both are
            // reachable from the CLI today (review m-2). The classification
            // is unaffected: it says what the outcome IS — a missing
            // permission on the key is an auth problem, an account with no
            // buckets is a remote-side fact.
            case .bucketListForbidden:
                return .auth
            case .bucketListEmpty:
                return .remote
            // A bucket is not a thing this tool writes to, renames or
            // deletes — the remote side said no by our own rule, which is
            // still a remote-side fact from the caller's point of view.
            case .bucketLevelRefused:
                return .remote
            // Same reading for the cross-bucket rename: our own rule said
            // no about a remote-side arrangement of objects.
            case .crossBucketRenameRefused:
                return .remote
            }
        default:
            return .connection
        }
    }

    /// Why a bucket-level operation was refused, in plain English (this
    /// file's own policy — CLI output is not localized).
    ///
    /// An exhaustive `switch` over a closed enum, which is the structural
    /// half of Task 3 review I-2: the previous version interpolated the raw
    /// method name and printed "macSCP does not createDirectory buckets".
    /// A case added to `BucketLevelOperation` now fails to compile here
    /// until someone writes its sentence.
    private static func refusalReason(
        _ operation: RemoteFSError.BucketLevelOperation
    ) -> String {
        switch operation {
        case .write:
            return "macSCP does not write to a bucket itself"
        case .delete:
            return "macSCP does not delete buckets"
        case .createDirectory:
            return "macSCP does not create folders beside the buckets"
        case .deleteTree:
            return "macSCP does not empty buckets"
        case .rename:
            return "macSCP does not rename buckets"
        case .presignedURL:
            return "macSCP does not sign links for a bucket itself"
        case .readStream:
            return "macSCP does not download a bucket as a file"
        }
    }

    /// A readable line for stderr. `ExitCode`'s own message is empty by
    /// design (see the CLI's `main()` override), so without this the user
    /// would see nothing at all rather than a bare case name — this is
    /// strictly better than today's "Error: secretRequired", not a
    /// replacement for proper localization (CLI output stays plain English
    /// per the project's language policy).
    public static func message(for error: Error) -> String {
        switch error {
        case let error as TransferSourceError:
            switch error {
            case .isDirectory(let path):
                return "Error: '\(path)' is a directory; get/put transfer a single file only"
            }
        case let error as DeleteSourceError:
            switch error {
            case .isDirectory(let path):
                return "Error: '\(path)' is a directory; pass --recursive to delete it and its contents"
            case .isSessionRoot(let path):
                return "Error: '\(path)' is the session root; pass --recursive --allow-root-delete "
                    + "to delete everything under it"
            }
        case let error as TransferPlanError:
            switch error {
            case .conflict(let path):
                return "Error: destination already exists: \(path) "
                    + "(pass --on-conflict skip or --on-conflict overwrite)"
            case .emptyDestinationDirectory:
                return "Error: destination directory is empty"
            }
        case let error as SessionReferenceError:
            switch error {
            case .unknown(let name):
                return "Error: no stored session named '\(name)' "
                    + "(or the path is missing its 'name:' session prefix)"
            case .ambiguous(let name, let count):
                return "Error: '\(name)' matches \(count) stored sessions; disambiguate by UUID"
            }
        case let error as DiagnoseUsageError:
            switch error {
            case .scopeNeedsASession(let scope):
                // The scope's own `rawValue`, never a second spelling of it
                // — the same rule `DiagnosticReport.scopeName(for:)` states
                // for the header line it prints.
                return "Error: --scope \(scope.rawValue) measures a stored session's own "
                    + "login; name a session instead of --host"
            }
        case let error as HostKeyError:
            switch error {
            case .mismatch(let host, let expected, let presented):
                return """
                    Error: host key MISMATCH for \(host) — expected \(expected), got \(presented). \
                    This can mean the host key legitimately changed, or a machine-in-the-middle attack. \
                    Not auto-resolvable: update the known-hosts entry only after confirming out of band.
                    """
            case .rejectedByUser:
                return "Error: unknown host key was not accepted "
                    + "(pass --accept-new to trust new hosts, or confirm interactively)"
            }
        case let error as StoredSessionConnectionError:
            switch error {
            case .loginSetSessionsNotSupported:
                return "Error: this session's credentials come from a login set, "
                    + "which the CLI does not resolve yet"
            case .jumpSessionsNotSupported:
                return "Error: this session dials through a jump host, "
                    + "which the CLI does not resolve yet"
            case .missingBackendConfiguration(let kind):
                // Names the protocol exactly as the two per-protocol messages
                // this replaced did (M22/T10) — the descriptor's badge label
                // is the one English name each backend already carries.
                return "Error: the stored session is missing its "
                    + "\(BackendDescriptor.descriptor(for: kind).badgeLabelDefault) configuration"
            case .secretRequired:
                // `.secretRequired` is a bare case (`StoredSessionConnectionConfig
                // .swift`) — nothing about which links THIS invocation actually
                // walked reaches this `switch`, only the fact that none of them
                // produced a secret. So this cannot single out a subset for one
                // session and a different subset for another; it names all four
                // links `secretSources(for:passwordCommand:keychainStore:keyStore:)`
                // (`CLISecretSources.swift`) can ever hold, in the chain's own
                // order, every time — the same choice this message already made
                // for `--password-command` (named even when the flag was never
                // passed) before this case grew a fourth link.
                return "Error: no secret available (checked --password-command, "
                    + "the environment, the keychain, and the managed key's passphrase)"
            case .incompleteConfiguration(let field):
                return "Error: the stored session's \(field) is missing or invalid"
            }
        case let error as TunnelStoreError:
            switch error {
            case .unreadable(let path):
                return "Error: the forwarding list \(path) could not be read, "
                    + "so it was not changed; check the file"
            }
        case let error as SFTPStartError:
            switch error {
            case .noResponse:
                return "Error: the server did not start SFTP; it may not offer SFTP at all"
            }
        // The log's sentence, not a second spelling of it: it names the file
        // and nothing read from it.
        case SSHKeyError.managedKeyStoreUnreadable:
            return "Error: " + DialSupport.reason(for: error)
        // The two arms allowed to print the error itself, by type
        // (`CLIErrorMappingTests.noCLIMessagePathRendersARawError`):
        // neither carries a secret or command output — the password
        // command's stdout never enters an error, and a `KeychainError` is a
        // status code.
        case is PasswordCommandError:
            return "Error: --password-command failed: \(error)"
        case is KeychainError:
            return "Error: keychain access failed: \(error)"
        case let error as RemoteFSError:
            switch error {
            case .authenticationFailed:
                return "Error: authentication failed"
            case .jumpAuthenticationFailed:
                return "Error: authentication to the jump host failed"
            // A backend's reason is kept — the CLI is where a person or a
            // script debugs a connection — but filtered, the way the
            // transfer queue shows it: the backends compose it, and a URL
            // they quote may carry `KEY:SECRET@`.
            case .connectionFailed(let reason):
                return "Error: connection failed: \(URLText.withoutUserinfo(reason))"
            case .notFound(let path):
                return "Error: not found: \(path)"
            case .permissionDenied(let path):
                return "Error: permission denied: \(path)"
            case .protocolError(let reason):
                return "Error: \(URLText.withoutUserinfo(reason))"
            case .bucketListForbidden:
                return "Error: this key may not list the account's buckets"
            case .bucketListEmpty:
                return "Error: this key may list buckets, but the account has none"
            case .bucketLevelRefused(let operation, let path):
                return "Error: \(path) is a bucket; \(Self.refusalReason(operation))"
            // Its OWN frame, not the one above: neither end is a bucket
            // here, so "<path> is a bucket" would say something false.
            case .crossBucketRenameRefused(let from, let to):
                return "Error: cannot rename \(from) to \(to); "
                    + "macSCP does not move objects between buckets"
            }
        default:
            // Never the error's own description (final review of the
            // 2026-09-19 small follow-ups). An `NSError`'s `description`
            // prints its whole `userInfo` — the failing URL among it,
            // userinfo component and all — so this line, which used to read
            // `"Error: \(error)"`, handed a stored WebDAV session's
            // `user:password@` to stderr whenever a `URLError` reached it.
            // Measured, not assumed, on the WebDAV path while the wrap sat
            // on its dial alone; the S3 download body broke the same wrapping
            // habit until the plan's Task 1 (found on the transfer queue,
            // `task-1-review.md`).
            //
            // The old comment here said the fallback was safe only while
            // every backend wraps a foreign error before it leaves — a habit
            // at each throw site, not a property of this switch. It no
            // longer rests on that habit: `DialSupport.reason(for:)` renders
            // an unmapped error as a fixed sentence or, for a foreign one,
            // as its localized sentence (never its description), and
            // `URLText.withoutUserinfo` cuts the userinfo out of any URL that
            // sentence quotes. That filter is a backstop with a documented
            // hole (a credential holding whitespace; one holding `/` too,
            // until 2026-09-19), which is why
            // the backends still wrap at the throw site and compose no text
            // out of a typed endpoint (`S3EndpointReason`).
            //
            // `DialSupport` rather than `CoreL10n`: CLI output stays plain
            // English, and `DialSupport`'s sentences are English.
            return "Error: \(URLText.withoutUserinfo(DialSupport.reason(for: error)))"
        }
    }
}
