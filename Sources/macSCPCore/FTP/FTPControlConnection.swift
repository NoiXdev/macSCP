import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import Security
import Synchronization
import os

/// The decider an unknown server certificate is put to.
///
/// WebDAV's type, aliased rather than re-declared: it is the same question —
/// a fingerprint a person compares against the server's own admin page — and
/// the app already composes one for the certificate prompt. A second type
/// would mean a second prompt wiring for the same decision.
typealias CertificateDecider = WebDAVSessionDelegate.CertificateDecider

/// Why an FTP control or data connection could not be opened, or could not
/// carry on.
///
/// **No case carries server text, a path or a credential.** A reply code is
/// the most any of them holds. The control channel this travels beside
/// carries `PASS`, some servers quote the client's command line back in their
/// replies, and the default description of an error prints its payload
/// verbatim — so what is not in the value cannot leak from it. The sentence a
/// user reads comes from `message`, which is this project's own text, in four
/// languages.
enum FTPConnectionFailure: Error, Equatable, Sendable {
    /// The greeting was not a positive reply — a `421` from a server that is
    /// full, or out of hours. `code` is the reply code.
    case greetingRefused(code: Int)
    /// Nothing that would end a wait arrived within the dial's own timeout.
    case timedOut
    /// The peer closed, or the transport failed, before the exchange
    /// finished. The two are one case on purpose: at FTP level both mean the
    /// control connection has ended, and telling them apart would mean
    /// carrying the transport's own words.
    case connectionClosed
    /// A line arrived that cannot be part of a reply, so the stream can no
    /// longer be read against the commands sent.
    case protocolViolation
    /// `AUTH TLS`, or the `PROT P` that follows it, was refused. There is no
    /// plaintext fallback: a connection the user asked to protect is not
    /// continued in the clear.
    case tlsUpgradeRefused(code: Int)
    /// The TLS handshake did not complete, for a reason that is not one of
    /// the certificate cases below.
    case tlsHandshakeFailed
    /// The login was refused.
    case loginRefused
    /// The certificate was declined — by the decider, or because the chain
    /// could not be read at all.
    case certificateRejected
    /// A remembered certificate and the presented one differ. A hard stop
    /// with no override, the same contract `HostKeyError.mismatch` has.
    case certificateMismatch
    /// The trusted-certificate store could not be read. Distinct from
    /// `certificateRejected` so nothing reports a refusal the user never
    /// made.
    case trustStoreUnreadable
    /// A data connection performing a FULL handshake presented certificate
    /// material that is not its control connection's, byte for byte
    /// (Ruling T5.1).
    case dataCertificateDiffers
    /// `TYPE I` was refused, so the server will not move bytes without
    /// rewriting them.
    ///
    /// Its own case because it is neither a login problem nor a malformed
    /// reply: the server answered a command it understood with a refusal.
    /// There is no fallback — `TYPE A` rewrites line endings, which corrupts
    /// every file that is not text — so the dial ends here. `code` is the
    /// reply code.
    case binaryModeRefused(code: Int)

    /// The user name or the password carries a character that cannot cross a
    /// command line (CR, LF or NUL), so the login was never sent.
    ///
    /// Its own case because the choke point's own refusal is a FILE's: it
    /// says "Rename the file or folder and try again", which is not what
    /// somebody whose password contains a line break needs to read. The case
    /// carries nothing, so neither the credential nor which of the two
    /// fields it was can reach a log or a failure message.
    case credentialNotSendable

    /// A TLS session was offered to a connection that does not belong to the
    /// control connection that established it. macSCP's own guard: the TLS
    /// library cannot make this comparison for a peer named by address.
    case sessionFromAnotherConnection
    /// A passive reply named no readable place at all.
    ///
    /// Unusable always means the reply being unreadable, and **both parsers
    /// throw this, with four throw sites each** — counted, not remembered:
    ///
    ///     /usr/bin/grep -c 'throw FTPConnectionFailure\.passiveAddressRefused' Sources/macSCPCore/FTP/FTPDataConnection.swift
    ///
    /// prints 8, and `-c` is the right tool because each site is its own
    /// line. The counting rule is one per CONDITION, so a compound guard
    /// contributes more than one.
    ///
    /// This comment first wrote that command as
    /// `/usr/bin/grep -c passiveAddressRefused Sources/macSCPCore/FTP/FTPDataConnection.swift`,
    /// which printed 8 when it was written and prints **9** now: the same
    /// commit that corrected the enumeration below added a prose line naming
    /// `FTPConnectionFailure.passiveAddressRefused` to
    /// `FTPDataConnection.openPassive(on:)`'s doc comment, and an unanchored
    /// search counts the sentence about the throw sites alongside the throw
    /// sites. Anchoring on `throw` is what makes the figure survive the next
    /// paragraph that mentions the case — the third point of CLAUDE.md's
    /// "A number travels with the command that produced it", arriving through
    /// the pattern rather than through the quoting.
    ///
    /// A `227` is unusable in **five** ways: no parenthesised address at
    /// all, not six comma-separated fields, a field that is not a number, an
    /// octet past 255, or a port of zero. Pinned by
    /// `#expect(unusable.count == 5)` in
    /// `FTPDataConnectionTests.aPASVReplyWithAnUnusableAddressIsRefusedRatherThanDialled`.
    ///
    /// A `229` carries **seven** conditions on its four sites — one, one,
    /// then three at `parts.count == 5, parts[0].isEmpty, parts[4].isEmpty`,
    /// then two at `let port = Int(parts[3]), (1...65535).contains(port)` —
    /// of which **six are reachable**: no parenthesised field, an empty
    /// field so no delimiter, not five delimiter-separated parts, a trailing
    /// part that is not empty, a port field that is not a number, or a port
    /// outside `1...65535`. The seventh, `parts[0].isEmpty`, cannot fail:
    /// the delimiter is `field.first`, so everything before its first
    /// occurrence is empty on every input. Pinned by
    /// `#expect(unusable.count == 6)` in
    /// `FTPDataConnectionTests.a229ThatCannotBeReadIsRefusedInEachOfItsSixWays`,
    /// which also demonstrates the unreachable one.
    ///
    /// The port check is wider than the `227`'s because six octets cannot
    /// express a port above 65535 while an `EPSV` reply's decimal field can;
    /// a port of zero is not a separate `229` way, only a value in that one
    /// range check.
    ///
    /// (Withdrawn wording, verbatim: "A `229` is unusable in four, and they
    /// are not the same four: no parenthesised field, a field with no first
    /// character to use as a delimiter, a field that is not five
    /// delimiter-separated parts with empty ends, or a port outside
    /// `1...65535`". Four is wrong by this comment's own rule — it split the
    /// `227`'s compound guard and left both of the `229`'s unsplit — and the
    /// list omitted "a port field that is not a number" entirely. Five,
    /// which Ruling T6.11's brief proposed, splits the port guard and still
    /// leaves `parts.count == 5, parts[0].isEmpty, parts[4].isEmpty` as one:
    /// counted by running the parser against each condition, it is seven
    /// written and six reachable. This is the second correction to this
    /// sentence, which is why it now cites the test that holds the number.)
    ///
    /// (Withdrawn wording, verbatim: "Unusable means one
    /// of five things, all of them the reply being unreadable: no
    /// parenthesised address at all, not six comma-separated fields, a field
    /// that is not a number, an octet past 255, or a port of zero." Those
    /// five are the `227` parser's, and this is the case-level comment for an
    /// error both parsers throw; "not six comma-separated fields" is not a
    /// thing `EPSV` ever requires.) The function-level count on
    /// `passiveEndpoint` is correctly scoped to the `227` and is pinned by
    /// `#expect(unusable.count == 5)`.
    ///
    /// **It is never a judgement about WHERE the reply points**: the
    /// host a passive reply names is read and then ignored, and the data
    /// connection always goes to the control connection's own peer
    /// (`FTPDataConnection.passiveEndpoint(_:peerHost:)`). Withdrawn wording,
    /// verbatim: "A passive reply named a place this client will not dial, or
    /// named no readable place at all", and "Unusable means one of four
    /// things: the reply carries no six-number address, one of its octets is
    /// past 255, its port is zero, or the address is not the peer the control
    /// connection is talking to. The last is the one with teeth — dialling it
    /// is the FTP bounce primitive, a server choosing on the client's behalf
    /// which host receives a connection, and under FTPS it could not work
    /// anyway, since a data connection has to present the control
    /// connection's own certificate byte for byte (Ruling T5.1)." The
    /// anti-bounce argument is kept, in its working form, at
    /// `passiveEndpoint(_:peerHost:)`; what is withdrawn is the comparison
    /// and the refusal it produced (Ruling T6.2).
    ///
    /// It carries no payload, so nothing the server named can reach a log or
    /// a failure message.
    case passiveAddressRefused
    /// Both `EPSV` and `PASV` were refused, so there is no way to open a data
    /// connection. `code` is the reply code `PASV` came back with.
    case passiveModeRefused(code: Int)
    /// The transfer command itself was refused, or its completion reply was
    /// not a `2xx`. `code` is the reply code.
    ///
    /// **Its sentence gives the user nothing to act on, and that is
    /// deliberate for now.** A `550 No such file` arrives here too, and it
    /// reads "The server refused the transfer." The code is in the payload
    /// and not in the text, so a layer that renders failures can tell them
    /// apart and say which it was; doing it in this sentence would mean one
    /// catalogue key per reply code, decided without the UI that shows them.
    /// A message that names the WRONG cause is worse than a general one, so
    /// the mapping waits for the task that owns rendering.
    case transferRefused(code: Int)
    /// `REST` was refused, so the offset a resumed transfer asked for cannot
    /// be honoured. `code` is the reply code.
    ///
    /// Its own case, and the transfer stops here, because the alternative is
    /// silent corruption: a client that carried on would receive the whole
    /// file and write it at the offset, leaving the file's head in the middle
    /// of it with no error anywhere.
    case restRefused(code: Int)

    /// A transfer was started on an `FTPTransferLease` that had already been
    /// given back to the pool.
    ///
    /// macSCP's own guard, and the last hole in the lease's structural
    /// boundary. Measured in the Task 6 review: a lease released
    /// `reusable: true`, whose connection the pool had already handed to a
    /// second lease, ran a complete `RETR` on it — one socket, two owners.
    /// Nothing but the control connection's command turn kept the two
    /// transfers from interleaving, and a desynchronised control connection
    /// is what §5a's rule about discarding exists to avoid.
    ///
    /// It carries no payload, and the transfer never reaches the wire, so
    /// the connection is left exactly as it was.
    case leaseAlreadyReturned

    /// The TLS library refused the session this connection offered.
    ///
    /// **Mapped, never surfaced.** `NIOSSLExtraError`'s own description for
    /// `cannotResumeSessionForDifferentServerHostname` embeds BOTH peer
    /// hostnames, and the type is `CustomStringConvertible`, so anything that
    /// logged or displayed it would print two peer-identifying strings. Four
    /// existing upstream descriptions do the same, which is why this mapping
    /// is macSCP's obligation rather than the fork's bug.
    case sessionRefusedByTLS

    /// Every case of this type as a payload-free tag, so that the set of
    /// them can be ITERATED.
    ///
    /// **This exists because a guard could not be held to the enum without
    /// it.** `everyConnectionFailureHasItsOwnSentence` built its set by
    /// iterating a hand-written list of failures and comparing its size to
    /// the literal `13`. Measured in the Task 5 review: a 14th case added to
    /// this enum, to its key mapping, and to the test's own exhaustive
    /// `switch` — with a key no catalog declares — left the test GREEN,
    /// because the set was populated only from that list, so a case missing
    /// from the list was never counted and `13` still held. An enum with
    /// associated values cannot be `CaseIterable`; a tag beside it can, and
    /// `kind` below is exhaustive over the failure, so neither set can grow
    /// without the other.
    enum Kind: String, CaseIterable, Sendable {
        case greetingRefused
        case timedOut
        case connectionClosed
        case protocolViolation
        case tlsUpgradeRefused
        case tlsHandshakeFailed
        case loginRefused
        case binaryModeRefused
        case credentialNotSendable
        case certificateRejected
        case certificateMismatch
        case trustStoreUnreadable
        case dataCertificateDiffers
        case sessionFromAnotherConnection
        case sessionRefusedByTLS
        case passiveAddressRefused
        case passiveModeRefused
        case transferRefused
        case restRefused
        case leaseAlreadyReturned

        /// This failure's catalog key. A case added without its four catalog
        /// entries is caught by `everyConnectionFailureHasItsOwnSentence`,
        /// which walks `allCases`; the lookup itself cannot fail loudly,
        /// since `CoreL10n.string` falls back to the key text.
        var messageKey: String {
            switch self {
            case .greetingRefused: "core.connect.ftpGreetingRefused"
            case .timedOut: "core.connect.ftpTimedOut"
            case .connectionClosed: "core.connect.ftpConnectionClosed"
            case .protocolViolation: "core.connect.ftpProtocolViolation"
            case .tlsUpgradeRefused: "core.connect.ftpTLSRequired"
            case .tlsHandshakeFailed: "core.connect.ftpTLSHandshakeFailed"
            // Not an FTP-specific sentence: a refused login reads the same
            // whichever protocol carried it, and this key already says it.
            case .loginRefused: "core.connect.authFailed"
            case .binaryModeRefused: "core.connect.ftpBinaryModeRefused"
            case .credentialNotSendable: "core.connect.ftpCredentialNotSendable"
            case .certificateRejected: "core.connect.ftpCertificateRejected"
            case .certificateMismatch: "core.connect.ftpCertificateMismatch"
            case .trustStoreUnreadable: "core.connect.ftpTrustStoreUnreadable"
            case .dataCertificateDiffers: "core.connect.ftpDataCertificateDiffers"
            case .sessionFromAnotherConnection: "core.connect.ftpSessionScope"
            case .sessionRefusedByTLS: "core.connect.ftpSessionRefused"
            case .passiveAddressRefused: "core.connect.ftpPassiveAddressRefused"
            case .passiveModeRefused: "core.connect.ftpPassiveModeRefused"
            case .transferRefused: "core.connect.ftpTransferRefused"
            case .restRefused: "core.connect.ftpRestRefused"
            case .leaseAlreadyReturned: "core.connect.ftpLeaseReturned"
            }
        }

        /// This kind as one fixed ENGLISH sentence, for the places that are
        /// not localized: the diagnostic log, the diagnosis report and the
        /// payload of a typed failure cause (Ruling T8.5).
        ///
        /// The split `RemoteFSFinding` states: `message` is the user's
        /// language, from the catalogue, for anything a person reads in the
        /// app; this is the paste artifact, the same in every locale. Written
        /// as a `switch` over the `CaseIterable` tag with no `default`, so a
        /// kind added without a sentence does not compile, and walked by
        /// `FTPFailureRenderingTests.everyKindHasAFixedEnglishLogSentenceOfItsOwn`.
        ///
        /// Like `messageKey` it holds no host, port, credential, fingerprint
        /// or reply code: a payload is the most any failure carries and none
        /// of it is read here.
        var logSentence: String {
            switch self {
            case .greetingRefused: "the FTP server refused the connection before the login"
            case .timedOut: "the FTP server did not answer in time"
            case .connectionClosed: "the connection to the FTP server ended"
            case .protocolViolation: "the FTP server sent a reply that could not be read"
            case .tlsUpgradeRefused: "the FTP server refused to switch to TLS"
            case .tlsHandshakeFailed: "the TLS handshake with the FTP server failed"
            case .loginRefused: "authentication failed"
            case .binaryModeRefused: "the FTP server refused binary transfer mode"
            case .credentialNotSendable:
                "the user name or password holds a character that cannot be sent in an FTP command"
            case .certificateRejected: "the server certificate was declined"
            case .certificateMismatch:
                "the server certificate differs from the one remembered for this server"
            case .trustStoreUnreadable: "the list of remembered certificates could not be read"
            case .dataCertificateDiffers:
                "a data connection presented a different certificate from the control connection"
            case .sessionFromAnotherConnection:
                "a TLS session was offered to a connection that did not establish it"
            case .sessionRefusedByTLS: "the TLS library refused the session offered for reuse"
            case .passiveAddressRefused: "the passive-mode reply named no usable address"
            case .passiveModeRefused: "the FTP server refused passive mode"
            case .transferRefused: "the FTP server refused the transfer"
            case .restRefused: "the FTP server refused to resume at an offset"
            case .leaseAlreadyReturned: "a transfer was started on a connection already handed back"
            }
        }
    }

    /// Which kind of failure this is, with the payload dropped.
    var kind: Kind {
        switch self {
        case .greetingRefused: .greetingRefused
        case .timedOut: .timedOut
        case .connectionClosed: .connectionClosed
        case .protocolViolation: .protocolViolation
        case .tlsUpgradeRefused: .tlsUpgradeRefused
        case .tlsHandshakeFailed: .tlsHandshakeFailed
        case .loginRefused: .loginRefused
        case .binaryModeRefused: .binaryModeRefused
        case .credentialNotSendable: .credentialNotSendable
        case .certificateRejected: .certificateRejected
        case .certificateMismatch: .certificateMismatch
        case .trustStoreUnreadable: .trustStoreUnreadable
        case .dataCertificateDiffers: .dataCertificateDiffers
        case .sessionFromAnotherConnection: .sessionFromAnotherConnection
        case .sessionRefusedByTLS: .sessionRefusedByTLS
        case .passiveAddressRefused: .passiveAddressRefused
        case .passiveModeRefused: .passiveModeRefused
        case .transferRefused: .transferRefused
        case .restRefused: .restRefused
        case .leaseAlreadyReturned: .leaseAlreadyReturned
        }
    }

    /// Whether a failure leaves the control connection it came from in step
    /// with the server, so the connection can carry the next command.
    ///
    /// The distinction the pool releases a lease by: a server that REFUSED a
    /// command answered it, and the reply stream is where it was; a
    /// connection that closed, timed out, or sent something unreadable is a
    /// connection nothing has established the state of, and §5a's rule is
    /// that such a connection is dropped rather than reused.
    ///
    /// **The five cases this task added are all in step**, and they are
    /// `passiveAddressRefused`, `passiveModeRefused`, `transferRefused`,
    /// `restRefused` and `leaseAlreadyReturned` — named rather than counted
    /// at the reader's expense, because a number in a comment is a claim
    /// about the rest of the project. (Withdrawn wording, verbatim: "The
    /// three refusals this task added are in step". It was written when four
    /// had been added, and a fifth has since joined them; it also called
    /// them all refusals, where two of the five are macSCP's own guard
    /// rather than a server's answer.) The count re-runs from the repository
    /// root, one key per line so `-c` is the right tool:
    ///
    ///     /usr/bin/grep -c -e ftpPassiveAddressRefused -e ftpPassiveModeRefused -e ftpTransferRefused -e ftpRestRefused -e ftpLeaseReturned Sources/macSCPCore/Resources/en.lproj/Localizable.strings
    ///
    /// **Four of the five are in step for one reason**, the one
    /// `aRefusedTransferCarriesNoCompletionReply` gives: the reply was the
    /// whole answer and nothing further is owed. That covers
    /// `passiveAddressRefused` too — a `PASV` or `EPSV` WAS written and its
    /// reply read in full there, and the refusal is this client's, after the
    /// exchange. (Withdrawn wording, verbatim: "`passiveAddressRefused` and
    /// `leaseAlreadyReturned` are in step because nothing was written to the
    /// wire at all." It is true of the second and false of the first, and
    /// the same commit's own case asserts the opposite:
    /// `#expect(verbs.contains("PASV"))` in
    /// `aPASVReplyWithAnUnusableAddressIsRefusedRatherThanDialled`.)
    ///
    /// `leaseAlreadyReturned` is the fifth, and nothing is written for it —
    /// **but its classification here is never consulted.**
    /// `FTPTransferLease.transferring` throws on a returned lease BEFORE the
    /// `do` whose `catch` calls `reusable(after:)`, and `readStream` refuses
    /// through the stream without reaching the drain at all. The case is in
    /// this arm because the `switch` is exhaustive and because `true` is the
    /// honest answer if anything ever did ask; it is inert today, and that is
    /// said here so the next reader does not go looking for the path that
    /// reads it.
    var leavesConnectionInStep: Bool {
        switch kind {
        case .passiveAddressRefused, .passiveModeRefused, .transferRefused, .restRefused,
            .leaseAlreadyReturned,
            .binaryModeRefused, .dataCertificateDiffers, .sessionFromAnotherConnection,
            .sessionRefusedByTLS, .certificateRejected, .certificateMismatch,
            .trustStoreUnreadable, .credentialNotSendable:
            true
        case .greetingRefused, .timedOut, .connectionClosed, .protocolViolation,
            .tlsUpgradeRefused, .tlsHandshakeFailed, .loginRefused:
            false
        }
    }

    /// This failure's catalog key, DERIVED from the case through `kind`.
    var messageKey: String { kind.messageKey }

    /// The localized sentence for this failure.
    var message: String { CoreL10n.string(messageKey) }

    /// The fixed English sentence for this failure (`Kind.logSentence`).
    var logSentence: String { kind.logSentence }
}

/// One FTP control connection: the socket, the greeting, the login, `FEAT`,
/// `TYPE I`, both TLS forms, and the `NOOP` that keeps an idle session from
/// being reaped.
///
/// **Commands are serialised, and there is one place that writes one.**
/// `send(_:argument:)` takes a turn before it writes and gives it up after
/// its reply, so a reply can never be read against the wrong command — an
/// actor alone does not buy that, since it is re-entrant at every `await`.
/// The line itself is built by `commandLine(_:argument:)`, the only function
/// here that spells a command terminator, and it takes both the verb and the
/// argument through `FTPPath.validated(_:)`
/// (`FTPControlConnectionTests.exactlyOnePlaceWritesACommandLine`).
///
/// **The password is one of those arguments**, which is deliberate: a
/// credential carrying CR LF would inject a command exactly as a file name
/// would, and it is refused by the same check, with the same refusal, which
/// names a character class and never the text.
actor FTPControlConnection {
    /// Which control connection this is. The scope a TLS session belongs to:
    /// a session established here is offered only to data connections opened
    /// for THIS identity (see `openDataConnection(host:port:protection:owner:timeout:idleTimeout:)`).
    struct Identity: Hashable, Sendable {
        private let raw = UUID()
    }

    /// The dial's dials. Separate from `FTPConnectionConfig`, which is the
    /// user's configuration; these are this layer's own numbers, and they
    /// exist as a parameter so a test can shorten one without a clock.
    struct Tuning: Sendable {
        /// How long a connection may be idle before `NOOP` is sent. Zero or
        /// less switches the keepalive off.
        var keepaliveInterval: Duration

        /// How long a reply may be SILENT before the control connection gives
        /// up on it. An idle bound, rearmed whenever a line arrives, so a
        /// multiline reply that keeps coming is never cut off by a total.
        ///
        /// Not the dial's `timeout`: that one bounds reaching the server, and
        /// it was doing this job too until fix round 1 — a 30-second dial
        /// bound capped every `226` at 30 seconds (R2).
        var replyIdleTimeout: Duration

        /// How long a data read may be SILENT before it gives up. The same
        /// kind of bound, on the other stream: a transfer that keeps
        /// delivering chunks has no total budget here, which is what a
        /// download of any size needs.
        var dataIdleTimeout: Duration

        init(
            keepaliveInterval: Duration = .seconds(30),
            replyIdleTimeout: Duration = .seconds(60),
            dataIdleTimeout: Duration = .seconds(120)
        ) {
            self.keepaliveInterval = keepaliveInterval
            self.replyIdleTimeout = replyIdleTimeout
            self.dataIdleTimeout = dataIdleTimeout
        }

        static let `default` = Tuning()
    }

    /// Everything ONE control connection's data connections need in order to
    /// protect themselves, and nothing another control connection could use.
    ///
    /// Ruling T5.1: a data connection that resumes `session` inherits the
    /// trust decision of the handshake that established it, which is correct
    /// — it is the same peer, vouched for once. A data connection that
    /// performs a FULL handshake has to present `controlCertificateDER` byte
    /// for byte, and asks nobody if it does not.
    struct DataProtection: Sendable {
        let owner: Identity
        /// The very context that established `session`. The library refuses
        /// a session offered on any other.
        let context: NIOSSLContext
        /// The SNI name the control connection sent — `nil` for a peer named
        /// by address, since an IP literal may not go in SNI.
        let serverHostname: String?
        /// The DER the control connection's own handshake accepted.
        let controlCertificateDER: [UInt8]
        /// A session to offer, or `nil` — then the handshake is a full one
        /// and the comparison above is what guards it.
        let session: NIOSSLSession?
        /// Where `session` is returned once the connection holding it has
        /// closed, so the next data connection of this control connection can
        /// be offered it. `nil` when no session is offered.
        let vault: FTPSessionVault?
    }

    nonisolated let identity = Identity()

    /// The host this connection was dialled with, exactly as the caller
    /// spelled it.
    ///
    /// Read by the passive negotiation, which refuses a `227` naming any
    /// other place (`FTPConnectionFailure.passiveAddressRefused`). Not
    /// `serverHostname`, which is `nil` for a peer named by address because
    /// an IP literal may not go in SNI — and a peer named by address is
    /// exactly the case the comparison is for.
    nonisolated let peerHost: String

    private let channel: Channel
    private let lines: FTPLineSource
    private let deliver: AsyncStream<ByteBuffer>.Continuation
    private let events: FTPChannelEvents
    private let trust: FTPTrustDecision
    private let tlsContext: NIOSSLContext?
    private let serverHostname: String?
    private let timeout: Duration
    private let tuning: Tuning
    /// The idle bound a reply is read under.
    ///
    /// The DIAL's own `timeout` until the dial is finished — a caller that
    /// says "give up after 10 seconds" means the whole business of reaching
    /// and greeting the server — and `tuning.replyIdleTimeout` from then on.
    /// One field and one assignment, at the end of `handshakeAndLogin`,
    /// rather than two bounds and a phase flag to read them by.
    private var replyBound: TimeAmount

    /// This control connection's TLS sessions, and which of them a data
    /// connection is holding right now. Scoped to this connection: see
    /// `openDataConnection(host:port:protection:owner:timeout:idleTimeout:)`.
    private let vault = FTPSessionVault()

    private var featureSet: Set<String> = []
    private var dataProtected = false
    private var commandInFlight = false
    private var waitingOrder: [UUID] = []
    private var waiting: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var keepalive: Task<Void, Never>?
    private var lastActivity = ContinuousClock.now
    private var isClosed = false
    /// This server answered `EPSV` with a refusal once, so the passive
    /// negotiation goes straight to `PASV` from now on
    /// (`FTPDataConnection.openPassive`). A memo, not a capability: `FEAT`
    /// does not have to list `EPSV`, so asking is the only way to find out,
    /// and asking once per connection is one round trip rather than one per
    /// transfer.
    private var extendedPassiveRefused = false

    private init(
        channel: Channel, lines: FTPLineSource, deliver: AsyncStream<ByteBuffer>.Continuation,
        events: FTPChannelEvents, trust: FTPTrustDecision, tlsContext: NIOSSLContext?,
        peerHost: String, serverHostname: String?, timeout: Duration, tuning: Tuning
    ) {
        self.peerHost = peerHost
        self.channel = channel
        self.lines = lines
        self.deliver = deliver
        self.events = events
        self.trust = trust
        self.tlsContext = tlsContext
        self.serverHostname = serverHostname
        self.timeout = timeout
        self.tuning = tuning
        self.replyBound = Self.timeAmount(timeout)
    }

    // MARK: - Dialling

    /// Opens a control connection, protects it as `config.security` asks,
    /// logs in, reads `FEAT` and sets binary mode.
    ///
    /// **`password` is the credential that is sent, and `config.password` is
    /// not read.** The two exist because the plan's interface says so; a
    /// caller that fills in only one fills in this one. A config built with
    /// an empty password and a real `password` argument is the shape the
    /// tests use, and it is the shape to prefer: a value type that never held
    /// the secret cannot print it.
    ///
    /// `timeout` bounds every wait the dial performs — the TCP connect, each
    /// reply, and each TLS handshake — rather than the dial as a whole, so
    /// nothing here can park past it waiting on a future that answers no
    /// cancellation.
    ///
    /// `trustStore` is where a certificate is looked up and remembered, and
    /// it has **no default** (Ruling T5.7). With `nil` every certificate is
    /// unknown to this layer, so `ServerCertificateValidation.evaluate`
    /// answers `.askUser` every time, nothing is ever pinned, and
    /// `.mismatch` — this project's hard stop and an architecture invariant —
    /// can never fire. A defaulted `nil` is a security-off switch a caller
    /// gets by typing nothing, and this is the whole security value of
    /// replacing the chain check with TOFU. A caller that really means
    /// "remember nothing" says `nil` out loud.
    static func connect(
        _ config: FTPConnectionConfig,
        password: String,
        certificateDecider: CertificateDecider,
        timeout: Duration,
        trustStore: TrustedCertificateStore?,
        tuning: Tuning = .default
    ) async throws -> FTPControlConnection {
        let host = config.host
        let port = config.port > 0 ? config.port : config.security.defaultPort
        let serverHostname = Self.sniName(for: host)
        let events = FTPChannelEvents()
        let (stream, continuation) = AsyncStream.makeStream(of: ByteBuffer.self)
        let trust = FTPTrustDecision(
            host: host, port: port, decider: certificateDecider, trustStore: trustStore)
        let tlsContext = config.security == .plain ? nil : try Self.clientContext()
        let wrapImmediately = config.security == .implicitTLS
        let verify = trust.verification

        let channel: Channel
        do {
            channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connectTimeout(Self.timeAmount(timeout))
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let pipeline = channel.pipeline.syncOperations
                        if wrapImmediately, let tlsContext {
                            try pipeline.addHandler(
                                NIOSSLClientHandler(
                                    context: tlsContext, serverHostname: serverHostname,
                                    customVerificationCallback: verify.callback))
                        }
                        try pipeline.addHandler(ByteToMessageHandler(FTPLineDecoder()))
                        try pipeline.addHandler(
                            FTPChannelSink(deliver: continuation, events: events))
                    }
                }
                .connect(host: host, port: port).get()
        } catch {
            continuation.finish()
            throw Self.dialFailure(error)
        }

        let connection = FTPControlConnection(
            channel: channel, lines: FTPLineSource(stream), deliver: continuation, events: events,
            trust: trust, tlsContext: tlsContext, peerHost: host, serverHostname: serverHostname,
            timeout: timeout, tuning: tuning)
        do {
            try await connection.handshakeAndLogin(
                security: config.security, username: config.username, password: password,
                tuning: tuning)
        } catch {
            await connection.close()
            throw error
        }
        return connection
    }

    /// The conversation `connect` is: wrap, greet, upgrade, log in, ask.
    private func handshakeAndLogin(
        security: FTPSecurityMode, username: String, password: String, tuning: Tuning
    ) async throws {
        if security == .implicitTLS { try await awaitHandshake() }

        let greeting = try await readGreeting()
        guard greeting.isPositiveCompletion else {
            throw FTPConnectionFailure.greetingRefused(code: greeting.code)
        }

        if security == .explicitTLS {
            // `234`, and nothing else. A 1xx would mean the upgrade has not
            // happened yet and a 3xx that the server wants something more
            // (`334` is the Kerberos-style "continue the exchange"); handing
            // either to `startTLS()` would send a ClientHello to a peer that
            // is not expecting one.
            let auth = try await send("AUTH", argument: "TLS")
            guard auth.isPositiveCompletion else {
                throw FTPConnectionFailure.tlsUpgradeRefused(code: auth.code)
            }
            try await startTLS()
            try await awaitHandshake()
        }

        if security != .plain {
            // `PBSZ 0` then `PROT P`, in that order (RFC 4217 section 9): the
            // buffer size is negotiated before the protection level, and a
            // server that refuses either leaves the data connections in the
            // clear, which is not what the user asked for.
            let buffer = try await send("PBSZ", argument: "0")
            guard buffer.isPositiveCompletion else {
                throw FTPConnectionFailure.tlsUpgradeRefused(code: buffer.code)
            }
            let protection = try await send("PROT", argument: "P")
            guard protection.isPositiveCompletion else {
                throw FTPConnectionFailure.tlsUpgradeRefused(code: protection.code)
            }
            dataProtected = true
        }

        // `USER` wants a 2xx or a 3xx, and nothing else (RFC 959 section 4.2,
        // the reply list for `USER`): `230` says no password is needed, `331`
        // asks for one, `332` asks for an account. The refusals are `530` and
        // `500`/`501`/`421`, and the list has no 1xx in it — a preliminary
        // reply promises a second one, so accepting it would carry the dial
        // on with every later reply answering the command before it, which is
        // what the `120` greeting did before it was read through (fix round 2,
        // F3). All of them are "this is not a login": the dial stops here and
        // `connect` closes the connection, so nothing reads the promised
        // follow-up against a later command.
        let user = try await sendCredential("USER", username)
        guard user.isPositiveCompletion || user.isIntermediate else {
            throw FTPConnectionFailure.loginRefused
        }
        if user.code != 230 {
            // `PASS` wants a 2xx. A `332 Need account for login` is a server
            // asking for an `ACCT` this backend does not send, and reading it
            // as a successful login would carry on against a session that is
            // not logged in.
            let accepted = try await sendCredential("PASS", password)
            guard accepted.isPositiveCompletion else { throw FTPConnectionFailure.loginRefused }
        }

        // `FEAT` is answered `211` with the list, or `500`/`502` by a server
        // that does not implement it (RFC 2389 section 3). An unimplemented
        // `FEAT` is not a failed dial — it is a server with no features to
        // report, and the empty set below says so. A 1xx is the one reply
        // this cannot take: it promises a second one, and reading it as the
        // answer leaves the stream one reply behind (fix round 2, F3).
        let feat = try await send("FEAT", argument: nil)
        guard !feat.isPreliminary else { throw FTPConnectionFailure.protocolViolation }
        featureSet = Self.features(of: feat)

        // Binary, once, and never `TYPE A`: a text-mode transfer rewrites
        // line endings, which corrupts every file that is not text.
        //
        // `TYPE` is answered `200`, or `500`/`501`/`504`/`421`/`530` (RFC 959
        // section 4.2). The reply was discarded with `_ =` until fix round 2
        // (F3), so a server that refused binary mode was carried on against
        // in text mode — and then every byte of every file that is not text
        // is rewritten in transit. There is no fallback worth having here:
        // the dial fails instead.
        let type = try await send("TYPE", argument: "I")
        guard type.isPositiveCompletion else {
            throw FTPConnectionFailure.binaryModeRefused(code: type.code)
        }

        startKeepalive(tuning.keepaliveInterval)
        // The dial is over, so the dial's bound is too: from here a reply is
        // read under the per-reply idle bound (R2).
        replyBound = Self.timeAmount(tuning.replyIdleTimeout)
    }

    /// Sends a command whose argument is a CREDENTIAL, reporting a refused
    /// one as a credential rather than as a path.
    ///
    /// Routing the two login arguments through `FTPPath.validated` is right —
    /// a user name or a password carrying CR LF injects a command exactly as
    /// a file name would — but the refusal it raises is a file's: the
    /// sentence behind `core.connect.ftpPathForbidden.lineFeed` tells the
    /// reader to rename a file, and `FTPPathRefusal` is not an
    /// `FTPConnectionFailure`, so it left `connect` as a type nothing above
    /// maps (fix round 1, R10). Neither the credential nor which of the two
    /// fields carried it is in what this throws.
    private func sendCredential(_ command: String, _ argument: String) async throws -> FTPReply {
        do {
            return try await send(command, argument: argument)
        } catch is FTPPathRefusal {
            throw FTPConnectionFailure.credentialNotSendable
        }
    }

    /// The greeting, reading through any preliminary replies in front of it.
    ///
    /// RFC 959 section 5.4 allows `120 Service ready in nnn minutes` followed
    /// by `220` when the greeting is ready. Taking the `120` as the greeting
    /// is not a refused connection — it is a stream one reply behind for the
    /// rest of its life, with every later reply answering the command before
    /// it and `FTPReplyAccumulator` unable to notice, because each line is a
    /// well-formed reply (fix round 1, R7).
    ///
    /// Bounded by a count as well as by the reply bound: a peer that answers
    /// `120` forever would otherwise be read forever, one bounded wait at a
    /// time.
    private func readGreeting() async throws -> FTPReply {
        var reply = try await readReply()
        var preliminaries = 0
        while reply.isPreliminary, preliminaries < Self.maximumPreliminaryGreetings {
            preliminaries += 1
            reply = try await readReply()
        }
        return reply
    }

    /// How many `1xx` replies may precede the greeting. One is what RFC 959
    /// describes; the allowance is for a server that repeats its estimate.
    private static let maximumPreliminaryGreetings = 4

    // MARK: - Commands

    /// What `FEAT` advertised, or an empty set before the dial has asked.
    var features: Set<String> { featureSet }

    /// Sends one command and returns its reply.
    ///
    /// Serialised: the caller takes a turn, writes, reads one reply and gives
    /// the turn up. Waiters are released in arrival order, each exactly once.
    ///
    /// `argument` crosses `FTPPath.validated(_:)` and so does `command`;
    /// a refusal is thrown as `FTPPathRefusal` before anything is written, so
    /// the wire never sees it.
    func send(_ command: String, argument: String? = nil) async throws -> FTPReply {
        let line = try Self.commandLine(command, argument: argument)
        try await acquire()
        defer { release() }
        lastActivity = .now
        do {
            try await channel.writeAndFlush(ByteBuffer(string: line)).get()
        } catch {
            throw FTPConnectionFailure.connectionClosed
        }
        let reply = try await readReply()
        lastActivity = .now
        return reply
    }

    /// A transfer command and BOTH of its replies, with the turn held across
    /// the work between them.
    ///
    /// `LIST`, `NLST`, `MLSD`, `RETR` and `STOR` answer twice: a preliminary
    /// `150` when the data connection opens and a `226` when it has closed,
    /// with the bytes moving in between.
    ///
    /// **Why this is one call and not two.** Until fix round 1 the second
    /// reply had its own method, `readFurtherReply()`, and `send` released the
    /// turn as soon as the `150` was read. Any command issued in between then
    /// consumed the `226` as its own reply, and the stream was one reply
    /// behind from that point on. Measured: a `PWD` issued after a `LIST`'s
    /// `150` came back `226` where `257` was due (R3). The brief's own
    /// requirement is that a reply can never be read against the wrong
    /// command, and for a transfer that means the turn has to span the pair.
    ///
    /// `body` runs with the turn HELD, so **it must not issue a command on
    /// this connection** — it would park on a turn it is itself holding.
    /// Draining or filling the data connection is the work that belongs
    /// there, and it is the only work that does.
    ///
    /// A refusal (`425`, `522`, `550`) is the whole answer and `completion`
    /// is `nil`: only a preliminary reply promises a second one, and waiting
    /// for one that is never coming would park until the idle bound.
    ///
    /// **A drain that THROWS still owes the completion reply** (fix round 2,
    /// F1, Ruling T5.11). The preliminary reply has promised a second one, and
    /// `defer { release() }` hands the turn to whoever is next as the error
    /// leaves this function, so an unguarded `try await body()` left the
    /// `226`/`426` inbound for the next command to read as its own — the very
    /// desynchronisation this method exists to prevent, reached through a
    /// throwing body instead of through an interleaving command. Measured
    /// before the fix: a `PWD` after a thrown drain came back **226** where
    /// `257` was due. The path is an ordinary one, not a corner: a
    /// `readToEnd()` that hits its own idle bound throws, and that is what a
    /// caller's drain is.
    ///
    /// So the reply is read under the reply bound before the original error is
    /// rethrown, and if THAT read fails the connection is closed: reading it
    /// keeps the control connection usable after a failed transfer, and
    /// closing on a failed read refuses to guess at a stream state nothing has
    /// established. The bounded read's own failure never replaces the reason
    /// the transfer failed.
    func transferCommand(
        _ command: String, argument: String? = nil,
        draining body: () async throws -> Void
    ) async throws -> (opening: FTPReply, completion: FTPReply?) {
        let line = try Self.commandLine(command, argument: argument)
        try await acquire()
        defer { release() }
        lastActivity = .now
        do {
            try await channel.writeAndFlush(ByteBuffer(string: line)).get()
        } catch {
            throw FTPConnectionFailure.connectionClosed
        }
        let opening = try await readReply()
        lastActivity = .now
        guard opening.isPreliminary else { return (opening, nil) }
        do {
            try await body()
        } catch {
            if await readOwedReplyUnderShield() {
                lastActivity = .now
            } else {
                await close()
            }
            throw error
        }
        let completion = try await readReply()
        lastActivity = .now
        return (opening, completion)
    }

    /// Reads the completion reply a failed drain still owes, SHIELDED from
    /// this task's cancellation, and answers whether it arrived.
    ///
    /// **The shield is the whole point, and it is a defect fix.** Cancelling
    /// a transfer must not take its control connection down with it: there is
    /// one control connection per tab, so a cancelled download that closed it
    /// would disconnect the tab. Without the shield the close was not a
    /// corner case but the ONLY outcome on that path — measured on the Task 5
    /// tree, where the first command after a cancelled transfer came back
    /// `connectionClosed` every time.
    ///
    /// Why it could not be otherwise there: an `AsyncStream` iteration in a
    /// cancelled task ends at once with no element — `next()` runs under a
    /// `withTaskCancellationHandler` whose handler terminates the stream, and
    /// an already-cancelled task runs it immediately — so `readReply()` saw
    /// an ended stream, threw `connectionClosed`, and the branch that closes
    /// the connection when the owed read fails ran on every cancel. The reply
    /// is usually right there: a server whose data connection the client
    /// closed answers `426 Transfer aborted` or `226`, and the bytes have
    /// often already arrived.
    ///
    /// An unstructured `Task` does not inherit its creator's cancellation
    /// (only its priority and its isolation), and awaiting its value does not
    /// observe the awaiting task's cancellation either, so the read inside it
    /// sees an uncancelled task and the stream behaves. The bound is still
    /// `readReply`'s own idle watchdog, so this cannot park: a server that
    /// says nothing ends the read as `timedOut`, which answers `false` and
    /// the connection is discarded, which is what "only discard when the
    /// shielded read fails" means.
    private func readOwedReplyUnderShield() async -> Bool {
        let read = Task { [self] in
            do {
                _ = try await readReply()
                return true
            } catch {
                return false
            }
        }
        return await read.value
    }

    /// The ONE place a command line is built, and the only function here that
    /// spells a command terminator.
    ///
    /// Both halves go through `FTPPath.validated(_:)`. The verb is this
    /// file's own text today, and it is validated anyway: a choke point that
    /// only checks the arguments is a choke point with a second entrance.
    private static func commandLine(_ command: String, argument: String?) throws -> String {
        var line = try FTPPath.validated(command)
        if let argument { line += " " + (try FTPPath.validated(argument)) }
        return line + "\r\n"
    }

    /// Reads one complete reply, joining a multiline one.
    ///
    /// Bounded by a watchdog on the channel's own event loop, not by a clock
    /// this function watches: a wait that goes quiet for longer than the bound
    /// ends as `timedOut` instead of parking whoever is awaiting it. The
    /// watchdog is rearmed by every line, so a multiline reply that keeps
    /// arriving is never cut off by a total.
    ///
    /// **A fired bound closes the connection.** Ending the line stream alone
    /// blinded it: `deliver` is this connection's only continuation, so
    /// finishing it kills every future read, while the socket stayed open and
    /// the keepalive went on writing `NOOP` into a connection nothing could
    /// read any more (fix round 1, R8). A connection whose stream has ended
    /// IS closed, so this says so.
    private func readReply() async throws -> FTPReply {
        let events = self.events
        let deliver = self.deliver
        let watchdog = FTPIdleWatchdog(bound: replyBound, loop: channel.eventLoop) {
            events.noteEnd(.timedOut)
            deliver.finish()
        }
        watchdog.start()
        defer { watchdog.stop() }

        var partial: [String] = []
        while let buffer = await lines.next() {
            watchdog.noteProgress()
            do {
                if let reply = try FTPReplyAccumulator.feed(String(buffer: buffer), into: &partial) {
                    return reply
                }
            } catch {
                throw FTPConnectionFailure.protocolViolation
            }
        }
        if events.end == .timedOut {
            await close()
            throw FTPConnectionFailure.timedOut
        }
        throw FTPConnectionFailure.connectionClosed
    }

    /// The features of a `FEAT` reply.
    ///
    /// Keyed twice on purpose: by the whole line and by its first word, so
    /// both questions a caller asks are answerable — `features.contains("MLSD")`
    /// and `features.contains("AUTH TLS")`. Uppercased, because RFC 2389
    /// section 3 makes feature names case-insensitive. The first and last
    /// lines of the reply are the human text around the list ("Features:",
    /// "End") and are not features.
    private static func features(of reply: FTPReply) -> Set<String> {
        var found: Set<String> = []
        for line in reply.lines.dropFirst().dropLast() {
            let text = line.trimmingCharacters(in: .whitespaces).uppercased()
            guard !text.isEmpty else { continue }
            found.insert(text)
            if let verb = text.split(separator: " ").first { found.insert(String(verb)) }
        }
        return found
    }

    // MARK: - The turn

    /// Whether a command turn is held right now.
    ///
    /// **Internal for one property**: that `transferCommand` holds the turn
    /// across BOTH of its replies. The observable consequence of losing the
    /// span — a reply reaching the wrong command — needs a second command on
    /// the wire while the pair is open, and a test that issued one only after
    /// `transferCommand` returned passed with the span removed: measured as
    /// GREEN, 32 tests, in the re-review of fix round 1 (fix round 2, F2).
    /// This flag is the property read directly, and
    /// `aTransferHoldsTheTurnAcrossBothOfItsReplies` reads it from inside the
    /// drain, where only a held turn can answer `true`.
    ///
    /// **Not the only way to see it, which fix round 2 claimed it was** (fix
    /// round 3, G1). Withdrawn verbatim, from the opening and from the middle
    /// of the paragraph above: "**Internal for one property nothing else can
    /// see**", and "a span removed by releasing the turn and re-acquiring it
    /// for the completion reply still serialises the two readers through the
    /// turn itself, so which of them reads the `226` is a matter of
    /// scheduling and not of the property". Sequencing the concurrent
    /// command's START against the drain — an `AsyncSignal` raised
    /// immediately before `send`, awaited as the drain's first statement —
    /// settles that race with no clock in it, and then which reader gets the
    /// `226` is exactly the property.
    /// `aCommandIssuedDuringATransferCannotReadItsCompletionReply` is that
    /// case, 20/20 red against the span plant and 20/20 green without it. The
    /// flag is kept BESIDE it rather than replaced by it: the flag cannot see
    /// a turn held with the two replies read in the wrong order, and the
    /// behavioural case cannot see a turn that is held and wrong — it reads
    /// only that nothing else reached the wire between the pair, which an
    /// implementation could also produce without holding a turn at all.
    var turnIsHeld: Bool { commandInFlight }

    /// How many callers are parked waiting for the turn.
    ///
    /// **Two cases read it, three times between them.** Re-run from the
    /// repository root:
    ///
    ///     /usr/bin/grep -rno 'connection\.turnWaiterCount' Tests
    ///
    /// prints **3** lines. Two are in
    /// `FTPControlConnectionTests.aWaiterForTheCommandTurnAnswersCancellation`
    /// — to know a waiter is really parked before it cancels one, since a
    /// cancellation that lands before the park takes `acquire()`'s own
    /// `Task.isCancelled` arm and never reaches the release the case exists
    /// to measure, and to know the cancelled waiter has been released, which
    /// is that case's hang bound. The third is in
    /// `theTurnIsHandedToExactlyOneWaiter`, for its own park.
    ///
    /// This paragraph first said **"One case reads it, three times"** and
    /// enumerated the three as **"the park, the release, and the queue read
    /// afterwards"**. Both were made false by the round that wrote them:
    /// `theTurnIsHandedToExactlyOneWaiter` is a second case, and the queue
    /// read afterwards was removed as an expectation that could not fail.
    /// The figure 3 was never wrong — the attribution was, which is why a
    /// reader re-running the command above was confirmed in it. It is spelled with the
    /// receiver and scoped to `Tests` for the reason
    /// `FTPConnectionPool.waiterCount`'s own comment gives: a bare
    /// `turnWaiterCount` over `Sources Tests` also matches every sentence
    /// that names it, so the figure moves as the prose around it is written
    /// — which happened twice while this paragraph was being written, the
    /// first draft having said three. A call-site count with a receiver in
    /// it cannot do that.
    var turnWaiterCount: Int { waitingOrder.count }

    /// Takes the turn, parking until it is free, and ANSWERS CANCELLATION
    /// while it parks (Ruling T6.3).
    ///
    /// **The wait could be as long as a file**, which is what made the bare
    /// `withCheckedContinuation` here a defect rather than untidiness: the
    /// turn is held across both of a transfer's replies, so a command issued
    /// during a download parked for the whole download and could not be
    /// cancelled. The same shape in `FTPConnectionPool.acquireTransfer` was
    /// measured outliving a 300-second time limit.
    ///
    /// It is also what makes `FTPTransferLease`'s concurrent-use path
    /// answerable: two `transferring` calls on one un-returned lease both
    /// pass the lease's own guard and are then serialised HERE, correctly —
    /// but the second one parks, and before this it parked uncancellably.
    ///
    /// **The fast path is deliberately NOT cancellation-checked.** A caller
    /// that finds the turn free is not made to fail for being cancelled: it
    /// writes its command and reads its reply, and the reply read has its own
    /// ending. What was unbounded, and is what this fixes, is the WAIT.
    ///
    /// Two races, closed on the actor and not with a second lock, the way
    /// `FTPConnectionPool.waitForASlot` closes its own: `onCancel` cannot
    /// touch actor state so it hops, and a hop that lands first finds no
    /// waiter — whereupon the body refuses to park, because the cancellation
    /// flag is set before `onCancel` runs. Removing the entry and resuming it
    /// happen in one actor step here and in `release()`, so the continuation
    /// is resumed exactly once and the turn is handed to exactly one waiter.
    private func acquire() async throws {
        if !commandInFlight {
            commandInFlight = true
            return
        }
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiting[identifier] = continuation
                waitingOrder.append(identifier)
            }
        } onCancel: {
            Task { await self.cancelTurnWaiter(identifier) }
        }
    }

    /// Releases one turn waiter with a `CancellationError`, if it is still
    /// waiting.
    ///
    /// A waiter `release()` has already taken out of `waiting` is not here
    /// any more, so a cancellation that arrives after the hand-off cannot
    /// take the turn away from the caller that was just given it.
    private func cancelTurnWaiter(_ identifier: UUID) {
        guard let continuation = waiting.removeValue(forKey: identifier) else { return }
        waitingOrder.removeAll { $0 == identifier }
        continuation.resume(throwing: CancellationError())
    }

    private func release() {
        guard let next = waitingOrder.first else {
            commandInFlight = false
            return
        }
        waitingOrder.removeFirst()
        waiting.removeValue(forKey: next)?.resume(returning: ())
    }

    // MARK: - TLS

    /// Adds the TLS handler to an established, cleartext pipeline — what
    /// `AUTH TLS` is, and the reason this backend is on NIO at all.
    ///
    /// The handler goes at the head, nearest the socket, so the line decoder
    /// above it sees decrypted bytes. It is built inside the event loop's own
    /// submission: a `ChannelHandler` is not `Sendable`, and this is the
    /// shape that hands one to a pipeline without carrying it across a
    /// concurrency boundary.
    private func startTLS() async throws {
        guard let tlsContext else { throw FTPConnectionFailure.tlsHandshakeFailed }
        let channel = self.channel
        let serverHostname = self.serverHostname
        let verify = trust.verification
        do {
            try await channel.eventLoop.submit {
                let handler = try NIOSSLClientHandler(
                    context: tlsContext, serverHostname: serverHostname,
                    customVerificationCallback: verify.callback)
                try channel.pipeline.syncOperations.addHandler(handler, position: .first)
            }.get()
        } catch {
            throw Self.dialFailure(error)
        }
    }

    /// Waits for the handshake this connection is in the middle of, and
    /// reports the precise reason when it does not complete: a refused or
    /// mismatched certificate is the trust decision's answer, not a generic
    /// handshake failure.
    private func awaitHandshake() async throws {
        switch await events.awaitHandshake(timeout: timeout) {
        case .some(true):
            return
        case .some(false):
            if let failure = trust.failure { throw failure }
            throw FTPConnectionFailure.tlsHandshakeFailed
        case .none:
            if let failure = trust.failure { throw failure }
            throw FTPConnectionFailure.timedOut
        }
    }

    /// A client context for FTPS.
    ///
    /// `certificateVerification` is `.noHostnameVerification`, and the two
    /// halves of that are separate decisions.
    ///
    /// It is not `.none`: the custom verification callback is NOT used when
    /// verification is off, so turning verification "off" would turn the
    /// trust decision off with it.
    ///
    /// It is not `.fullVerification` either, because that one re-checks the
    /// hostname AFTER the callback has accepted the certificate, and a peer
    /// named by address has no name to check: measured 2026-11-06 against the
    /// loopback server, where the dial failed with
    /// `NIOSSLExtraError.failedToValidateHostname: Couldn't find <none> in
    /// certificate from peer` while the decider had already said yes. An IP
    /// literal cannot be sent in SNI, so `serverHostname` is `nil` for every
    /// FTPS server reached by address, and under full verification none of
    /// them could connect.
    ///
    /// What the trust decision rests on instead is the fingerprint, which is
    /// the identity TOFU compares — the same one `HostKeyValidation` uses for
    /// a host key, and a stronger statement about this peer than a name in a
    /// certificate it also chose.
    ///
    /// **What this does not do, named rather than left for a reader to
    /// discover:** the callback replaces the chain check outright, so a
    /// publicly-trusted FTPS certificate is treated exactly like a
    /// self-signed one — unknown, and put to the decider. WebDAV's path
    /// differs here, because `URLSession` validates the chain first and only
    /// asks when that fails.
    private static func clientContext() throws -> NIOSSLContext {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv12
        configuration.certificateVerification = .noHostnameVerification
        return try NIOSSLContext(configuration: configuration)
    }

    // MARK: - Data connections

    /// The protection this control connection's next data connection must
    /// use, or `nil` when the data connections are in the clear (`PROT P` was
    /// never issued, or this is plain FTP).
    ///
    /// **The sessions are read HERE and not at handshake completion.** Under
    /// TLS 1.3 the peer issues them in `NewSessionTicket` messages after the
    /// handshake, so `establishedTLSSessions` is normally empty when the
    /// handshake-completed event fires and fills in as those messages are
    /// read. By the time a data connection is wanted, at least one reply has
    /// been read since the handshake, and TLS records are processed in order.
    ///
    /// Which session, and why one can come round again, is
    /// `FTPSessionVault`'s: a session is held by at most one data connection
    /// at a time, and is offered again once that connection has closed.
    func dataProtection() async -> DataProtection? {
        guard dataProtected, let tlsContext,
            let accepted = trust.acceptedCertificateDER
        else { return nil }
        let sessions = (try? await channel.nioSSL_establishedTLSSessions().get()) ?? []
        let offer = vault.checkOut(from: sessions)
        return DataProtection(
            owner: identity, context: tlsContext, serverHostname: serverHostname,
            controlCertificateDER: accepted, session: offer,
            vault: offer == nil ? nil : vault)
    }

    /// Whether this server has already refused `EPSV` on this connection.
    var prefersClassicPassive: Bool { extendedPassiveRefused }

    /// Remembers that `EPSV` was refused here.
    func noteExtendedPassiveRefused() {
        extendedPassiveRefused = true
    }

    /// Opens a data connection for THIS control connection, with this
    /// connection's own protection.
    ///
    /// **The scoping guard is structural here, not a check.** The static
    /// below takes an `owner:` argument and refuses a mismatch at run time;
    /// this one derives both the protection and the owner from `self`, so a
    /// data connection paired with another control connection's session
    /// cannot be written. Every caller in the backend goes through this one
    /// (`FTPDataConnection.openPassive`); the static's argument check remains
    /// for the test that pins the refusal.
    func openDataConnection(host: String, port: Int) async throws -> FTPDataChannel {
        try await Self.openDataConnection(
            host: host, port: port, protection: await dataProtection(), owner: identity,
            timeout: timeout, idleTimeout: tuning.dataIdleTimeout)
    }

    /// Opens a data connection, refusing a protection that belongs to another
    /// control connection.
    ///
    /// **This refusal is macSCP's, because the library cannot make it.** The
    /// fork compares the originating `NIOSSLContext` and the SNI server name;
    /// for a peer named by address both names are `nil` — an IP literal may
    /// not go in the SNI extension — so a session established against one
    /// address passes its check when offered to another. The peer's address is
    /// not reachable where that check runs: it sits in
    /// `NIOSSLClientHandler`'s designated initializer, before the handler is
    /// in a pipeline and before the channel has connected. macSCP knows which
    /// control connection a data connection belongs to, so the comparison is
    /// here, on the identity that owns the session.
    ///
    /// Ruling T5.1 also lives here, in `verify`: a FULL handshake must
    /// present the control connection's certificate material byte for byte,
    /// and a data connection never asks the user — the question was answered
    /// once, on the control connection, and asking it per transfer is how a
    /// person is trained to click yes.
    /// - Parameter timeout: bounds OPENING the connection — the TCP connect
    ///   and the TLS handshake. It is not a read budget: `idleTimeout` is.
    /// - Parameter idleTimeout: how long a read of this connection may be
    ///   silent before it gives up, rearmed by every chunk. Passing the dial's
    ///   figure here is what capped every download at the connect timeout
    ///   until fix round 1 (R2), so it has no default.
    static func openDataConnection(
        host: String, port: Int, protection: DataProtection?, owner: Identity,
        timeout: Duration, idleTimeout: Duration
    ) async throws -> FTPDataChannel {
        if let protection, protection.owner != owner {
            // The session goes back before the throw. Every other failure
            // path below checks it in, and this one used to be the exception
            // only because it precedes the plumbing: a refusal left a session
            // marked held with no holder that would ever return it.
            if let session = protection.session { protection.vault?.checkIn(session) }
            throw FTPConnectionFailure.sessionFromAnotherConnection
        }
        let events = FTPChannelEvents()
        let (stream, continuation) = AsyncStream.makeStream(of: ByteBuffer.self)
        let expected = protection?.controlCertificateDER
        let outcome = FTPDataTrustOutcome()
        // Read from the verification callback's own argument, which on a
        // session-offering connection is the ONLY source: that initializer
        // takes a plain `NIOSSLCustomVerificationCallback`, so
        // `peerValidatedCertificateChain` can never be non-nil there, and
        // `NIOSSLHandler.peerCertificate` returns the SESSION's cached leaf —
        // non-nil for a resumed peer that presented nothing at all, which
        // would make this comparison pass on any resumed connection.
        let verify = FTPVerification { certificates, promise in
            guard let leaf = certificates.first, let der = try? leaf.toDERBytes(),
                let expected, der == expected
            else {
                outcome.noteDiffers()
                promise.succeed(.failed)
                return
            }
            promise.succeed(.certificateVerified)
        }

        let channel: Channel
        do {
            channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connectTimeout(Self.timeAmount(timeout))
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let pipeline = channel.pipeline.syncOperations
                        if let protection {
                            let handler: NIOSSLClientHandler
                            if let session = protection.session {
                                handler = try NIOSSLClientHandler(
                                    context: protection.context,
                                    serverHostname: protection.serverHostname,
                                    sessionToResume: session,
                                    customVerificationCallback: verify.callback)
                            } else {
                                handler = try NIOSSLClientHandler(
                                    context: protection.context,
                                    serverHostname: protection.serverHostname,
                                    customVerificationCallback: verify.callback)
                            }
                            try pipeline.addHandler(handler)
                        }
                        try pipeline.addHandler(
                            FTPChannelSink(deliver: continuation, events: events))
                    }
                }
                .connect(host: host, port: port).get()
        } catch {
            continuation.finish()
            if let session = protection?.session { protection?.vault?.checkIn(session) }
            throw Self.dialFailure(error)
        }

        var resumed = false
        if protection != nil {
            switch await events.awaitHandshake(timeout: timeout) {
            case .some(true):
                resumed = (try? await channel.nioSSL_tlsSessionWasResumed().get()) ?? false
            case .some(false):
                continuation.finish()
                _ = try? await channel.close().get()
                // The session goes back whatever ended the handshake: a
                // connection that never opened is not holding it.
                if let session = protection?.session { protection?.vault?.checkIn(session) }
                throw outcome.differs
                    ? FTPConnectionFailure.dataCertificateDiffers
                    : FTPConnectionFailure.tlsHandshakeFailed
            case .none:
                continuation.finish()
                _ = try? await channel.close().get()
                if let session = protection?.session { protection?.vault?.checkIn(session) }
                throw FTPConnectionFailure.timedOut
            }
        }
        return FTPDataChannel(
            channel: channel, chunks: FTPLineSource(stream), deliver: continuation, events: events,
            didResumeTLSSession: resumed, bound: Self.timeAmount(idleTimeout),
            session: protection?.session, vault: protection?.vault)
    }

    // MARK: - Keepalive

    /// Sends `NOOP` once the connection has been idle for `interval`.
    ///
    /// Many FTP servers reap an idle control connection (vsftpd's
    /// `idle_session_timeout` defaults to 300 s), and a pooled connection
    /// spends most of its life idle.
    private func startKeepalive(_ interval: Duration) {
        guard interval > .zero else { return }
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self else { return }
                await self.sendKeepaliveIfIdle(interval)
            }
        }
    }

    private func sendKeepaliveIfIdle(_ interval: Duration) async {
        guard !isClosed, ContinuousClock.now - lastActivity >= interval else { return }
        // A keepalive that fails is not this connection's error to report:
        // whatever ended the connection will be reported by the next real
        // command, with its own context.
        _ = try? await send("NOOP", argument: nil)
    }

    // MARK: - Closing

    /// Ends the connection. Idempotent, and it cannot throw: a caller closing
    /// a connection has nothing left to do about a failure.
    ///
    /// No `QUIT`. A graceful goodbye would mean one more write and one more
    /// reply to wait for on a connection the caller has already finished
    /// with, and a server that has stopped answering would hold the close
    /// open; the UI owns lifecycles here, and what it asks for is that the
    /// connection be gone when this returns.
    func close() async {
        guard !isClosed else { return }
        isClosed = true
        keepalive?.cancel()
        keepalive = nil
        deliver.finish()
        _ = try? await channel.close().get()
    }

    // MARK: - Odds and ends

    /// The name to send in SNI, or `nil` for a peer named by address.
    ///
    /// An IP literal in the SNI extension is refused by the library
    /// (`NIOSSLExtraError.cannotUseIPAddressInSNI`), so an address peer has
    /// no SNI name — which is also why the library's session-hostname check
    /// compares `nil` with `nil` and why the scoping guard above exists.
    private static func sniName(for host: String) -> String? {
        (try? SocketAddress(ipAddress: host, port: 0)) == nil ? host : nil
    }

    /// `timeout` as NIO's own unit, clamped at zero — a negative bound would
    /// be a timer that has already fired.
    private static func timeAmount(_ timeout: Duration) -> TimeAmount {
        let components = timeout.components
        let nanoseconds =
            components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
        return .nanoseconds(max(0, nanoseconds))
    }

    /// What a failure from the TLS or transport layer is reported as.
    ///
    /// The two session errors are MAPPED and never surfaced: their
    /// descriptions embed both peer hostnames (see
    /// `FTPConnectionFailure.sessionRefusedByTLS`).
    private static func dialFailure(_ error: any Error) -> FTPConnectionFailure {
        if let failure = error as? FTPConnectionFailure { return failure }
        if let extra = error as? NIOSSLExtraError {
            if extra == .cannotResumeSessionFromDifferentContext
                || extra == .cannotResumeSessionForDifferentServerHostname
            {
                return .sessionRefusedByTLS
            }
            return .tlsHandshakeFailed
        }
        return .connectionClosed
    }
}

// MARK: - One data connection

/// The client end of one FTP data connection: it carries bytes and nothing
/// else, and it is opened only through
/// `FTPControlConnection.openDataConnection(host:port:protection:owner:timeout:idleTimeout:)`.
actor FTPDataChannel {
    private let channel: Channel
    private let chunks: FTPLineSource
    private let deliver: AsyncStream<ByteBuffer>.Continuation
    private let events: FTPChannelEvents
    private let bound: TimeAmount
    /// The session this connection offered, and where it goes back to. Held
    /// until `close()`, so no other data connection is offered it in the
    /// meantime (`FTPSessionVault`).
    private let session: NIOSSLSession?
    private let vault: FTPSessionVault?
    /// `close()` has run. The control connection's `close()` has had this
    /// guard from the start; this one did not, and a second call returned a
    /// session that by then belonged to another holder — see `close()`.
    private var isClosed = false

    /// Whether this connection's handshake resumed its control connection's
    /// TLS session instead of performing a full one. `false` on a clear data
    /// connection, which has no handshake to resume.
    ///
    /// This is the CLIENT's reading, from the TLS library. A test that wants
    /// to know whether a resumption really happened asks the server, which
    /// reads it off the wire — a client and a server asking the same library
    /// the same question would agree even when the library is wrong.
    nonisolated let didResumeTLSSession: Bool

    init(
        channel: Channel, chunks: FTPLineSource, deliver: AsyncStream<ByteBuffer>.Continuation,
        events: FTPChannelEvents, didResumeTLSSession: Bool, bound: TimeAmount,
        session: NIOSSLSession?, vault: FTPSessionVault?
    ) {
        self.channel = channel
        self.chunks = chunks
        self.deliver = deliver
        self.events = events
        self.didResumeTLSSession = didResumeTLSSession
        self.bound = bound
        self.session = session
        self.vault = vault
    }

    /// Everything the server sends until it closes the connection.
    ///
    /// Bounded by silence, not by a total: the watchdog is rearmed by every
    /// chunk, so a transfer that keeps moving is never cut off. One timer for
    /// the whole read, which is what this had until fix round 1, is a total
    /// budget — and it was the DIAL's figure, so a 30-second connect timeout
    /// capped every download at 30 seconds (R2).
    func readToEnd() async throws -> Data {
        var data = Data()
        try await read { data.append($0) }
        return data
    }

    /// Everything the server sends, handed to `sink` one chunk at a time.
    ///
    /// The shape a download of any size needs: `readToEnd()` is this with an
    /// appending sink, and a caller that writes each chunk to disk or yields
    /// it to a stream never holds the file in memory.
    ///
    /// The sink is `async`, which is what lets it exert BACK PRESSURE: the
    /// read does not go on until the sink returns, so a consumer that is
    /// slower than the network slows the reader instead of filling a buffer
    /// with the rest of the file (`FTPTransferLease.readStream`).
    ///
    /// **A cancelled read throws rather than returning what it got.** An
    /// `AsyncStream` iteration in a cancelled task ends with no element,
    /// exactly as a peer that closed does, so without the check below a
    /// cancelled download returned its partial bytes as a COMPLETE transfer
    /// — a silently truncated file, which is the one anti-goal §6 names. The
    /// check is after the loop and not inside it: a chunk that arrived is
    /// handed on either way, and it is the ending that is misreported.
    func read(into sink: (Data) async throws -> Void) async throws {
        let events = self.events
        let deliver = self.deliver
        let watchdog = FTPIdleWatchdog(bound: bound, loop: channel.eventLoop) {
            events.noteEnd(.timedOut)
            deliver.finish()
        }
        watchdog.start()
        defer { watchdog.stop() }

        while let chunk = await chunks.next() {
            watchdog.noteProgress()
            try await sink(Data(chunk.readableBytesView))
        }
        if events.end == .timedOut { throw FTPConnectionFailure.timedOut }
        try Task.checkCancellation()
    }

    func write(_ data: Data) async throws {
        do {
            try await channel.writeAndFlush(ByteBuffer(bytes: data)).get()
        } catch {
            throw FTPConnectionFailure.connectionClosed
        }
    }

    /// Ends the connection and returns its session. Idempotent.
    ///
    /// **The guard is not politeness, it is the C.4 invariant.** `checkIn` is
    /// a set removal, so returning the same session twice is harmless by
    /// itself; what is not harmless is the second return landing after
    /// another holder has taken that session out again, because the mark it
    /// clears is then somebody else's and the next checkout hands a held
    /// session to a second connection. A `defer { await data.close() }`
    /// beside an explicit close on an error path is how the second call
    /// arrives. Measured as `handedOutWhileHeld → true` before this guard
    /// existed; `aDataChannelClosedTwiceDoesNotReissueAHeldSession` is the
    /// case.
    func close() async {
        await close(returningSession: true)
    }

    /// The same, with the choice of whether the session goes back.
    ///
    /// `returningSession: false` DROPS it: the vault still marks it held, so
    /// it is never offered again. That is what a server answering `522` after
    /// a resumed handshake has said about it — the session it issued will not
    /// do — and offering it to the retry would make the retry fail for the
    /// reason the first attempt did.
    func close(returningSession: Bool) async {
        guard !isClosed else { return }
        isClosed = true
        deliver.finish()
        _ = try? await channel.close().get()
        // Returned after the channel is closed, not before: while this
        // connection is open it is the one holding the session.
        if returningSession, let session, let vault { vault.checkIn(session) }
    }
}

/// The TLS sessions ONE control connection has: which of them a data
/// connection is holding right now, and which have never been offered.
///
/// **This type deviates from what the TLS library asks of its callers, and
/// says so.** BoringSSL's own header states the obligation, in the comment
/// block on `SSL_SESSION_should_be_single_use`
/// (`.build/checkouts/swift-nio-ssl/Sources/CNIOBoringSSL/include/CNIOBoringSSL_ssl.h`,
/// found with
/// `/usr/bin/grep -n 'clients retain multiple sessions' <that file>`, which
/// prints one line — 2188 on the `2.37.6-noix.2` checkout):
///
///     // SSL_SESSION_should_be_single_use returns one if `session` should be
///     // single-use (TLS 1.3 and later) and zero otherwise.
///     //
///     // If this function returns one, clients retain multiple sessions and use each
///     // only once. This prevents passive observers from correlating connections with
///     // tickets. See RFC 8446, appendix C.4. If it returns zero, `session` cannot be
///     // used without leaking a correlator.
///
/// So the obligation is about LINKABILITY, not about the key schedule: the
/// closing sentence says the whole knob is about correlators. This vault
/// offers a session again once the connection holding it has closed, and
/// therefore spends an unlinkability property and nothing else.
///
/// **What strictness costs, measured 2026-11-06** against
/// `LoopbackFTPServer` with `requiresTLSSessionReuse: true`, four data
/// connections in a row on one control connection, printing whether a session
/// was offered, whether the handshake resumed, and the reply to `LIST`:
///
///     1: offered=true  resumed=true  reply=150
///     2: offered=true  resumed=true  reply=150
///     3: offered=false resumed=false reply=522
///     4: offered=false resumed=false reply=522
///
/// with `refusedDataConnectionCount` at 2 and the server's own handshake
/// journal reading `control/false, data/true, data/true, data/false,
/// data/false`. BoringSSL issues two tickets per handshake as a server and
/// the fixture renews none, so under "each only once" a control connection
/// has exactly two resumptions in it. vsftpd defaults `require_ssl_reuse` to
/// on: that is a backend that stops transferring after the second file.
/// Harvesting new sessions from the data connections is not an answer — the
/// same run read `establishedTLSSessions` on each data channel after its
/// transfer and got **0** every time, because the server closes a data
/// connection as soon as the transfer ends. Re-measured with reuse: **4 of
/// 4** resumed, `refusedDataConnectionCount` 0, the journal `control/false`
/// then four `data/true`.
///
/// **What the deviation actually spends.** Not the link from the data
/// connections to the control connection: `require_ssl_reuse` is a
/// SERVER-SIDE check and puts no correlator on the wire, and under TLS 1.3
/// the control connection's `NewSessionTicket` messages are post-handshake
/// and travel under application traffic keys, so a passive observer never
/// sees the ticket it was issued. What the observer does see in the clear is
/// the `pre_shared_key` identity in each data `ClientHello` — so reuse links
/// the data connections **to each other**, and those are already linked, by
/// the destination address the `PASV` reply named in cleartext and by their
/// timing inside one FTP session. That is the whole argument. (Withdrawn
/// wording from this project's record, verbatim: "the half of RFC 8446
/// appendix C.4 that remains is the one about CONCURRENT offers, which is
/// what the dispatch's ruling asks for" — the dispatch sentence it rested on
/// was retracted, and C.4 is about linkability, which does not care whether
/// two uses overlap in time.)
///
/// **A never-used session is preferred to a returned one, and that is
/// load-bearing.** Handing back the oldest unheld session means data
/// connection 2 re-offers the ticket connection 1 has just returned instead
/// of the untouched second one; a server that enforces single-use
/// consumption refuses that re-offer, falls back to a full handshake, and
/// `require_ssl_reuse` makes it `522` — so the policy would fail at
/// connection 2 where strictness reached 3. A policy adopted to raise a cap
/// must not lower it. `theVaultPrefersANeverUsedSessionOverAReturnedOne`
/// pins the order, with three sessions, because two cannot show it.
///
/// **Two consequences for later tasks, named rather than left to be found.**
/// The cap is not removed, only moved from sequence to concurrency: reuse
/// makes SEQUENTIAL data connections resume indefinitely and does nothing for
/// concurrent ones, since a checkout with every ticket held returns
/// `session: nil`, which is a full handshake, which a `require_ssl_reuse`
/// server answers `522`. A transfer queue running three data connections at
/// once over one control connection therefore fails on the third — the same
/// failure strictness produced, reached by concurrency instead of by count.
/// Task 6 either serialises data connections per control connection or opens
/// a control connection per concurrent transfer. And N data connections now
/// derive from one resumption secret instead of N: with `psk_dhe_ke` each
/// still performs its own DH exchange, so forward secrecy survives, but
/// nothing here may enable 0-RTT early data, for which single-use tickets are
/// also the server's anti-replay primitive.
///
/// A session whose holder never closes stays checked out. That degrades to a
/// full handshake, which is the direction this fails in anyway, and the UI
/// owning lifecycles explicitly is this project's standing answer to it.
///
/// The two things `FTPSessionVault` reads of a session, so that its order can
/// be tested with more sessions than a handshake hands out.
///
/// `NIOSSLSession` cannot be built in a test — its initializer takes ownership
/// of a BoringSSL `SSL_SESSION` that only a handshake produces — and the peer
/// issues two, where the vault's preference needs three to be visible. The
/// protocol is this project's, so conforming the library's type to it is ours
/// to declare.
protocol FTPResumableSession: AnyObject, Sendable {
    /// The session is complete and carries a session ID or ticket.
    var isResumable: Bool { get }
    /// The session should be offered at most once (TLS 1.3 and later).
    var shouldBeSingleUse: Bool { get }
}

extension NIOSSLSession: FTPResumableSession {}

final class FTPSessionVault: Sendable {
    private struct Inner {
        /// Sessions a live holder has not returned yet.
        var held: Set<ObjectIdentifier> = []
        /// Sessions that have been offered at least once. The fallback set:
        /// a session in here is only offered again when nothing untouched is
        /// left.
        var used: Set<ObjectIdentifier> = []
    }

    private let state = Mutex(Inner())

    /// A resumable session nothing is holding: the oldest NEVER-OFFERED one,
    /// or, when every one the peer issued has been offered already, the
    /// oldest returned one. `nil` when the peer has issued none yet or every
    /// one it issued is held.
    ///
    /// Oldest first within each of the two groups, which is the order
    /// `establishedTLSSessions` hands them out in: a session expires, so
    /// spending the oldest first keeps the supply from aging out underneath
    /// the connection. Why never-used comes first is on the type.
    ///
    /// A session the library does not mark single-use is handed out without
    /// being held: `shouldBeSingleUse == false` means the header's "cannot be
    /// used without leaking a correlator", so there is no per-use obligation
    /// to keep for it.
    func checkOut<Session: FTPResumableSession>(from sessions: [Session]) -> Session? {
        state.withLock { inner in
            let resumable = sessions.filter(\.isResumable)
            let free = resumable.filter { !inner.held.contains(ObjectIdentifier($0)) }
            let offer =
                free.first { !inner.used.contains(ObjectIdentifier($0)) } ?? free.first
            guard let offer else { return nil }
            let key = ObjectIdentifier(offer)
            inner.used.insert(key)
            if offer.shouldBeSingleUse { inner.held.insert(key) }
            return offer
        }
    }

    /// Gives a session back, so it can be offered again once nothing
    /// untouched is left.
    ///
    /// Idempotent on the set, and that is NOT enough on its own: a second
    /// return arriving after another holder has taken the same session out
    /// clears that holder's mark. Keeping `close()` idempotent is what makes
    /// this safe, and `FTPDataChannel.close()` says so.
    func checkIn(_ session: some FTPResumableSession) {
        state.withLock { _ = $0.held.remove(ObjectIdentifier(session)) }
    }
}

// MARK: - Channel plumbing

/// Ends a read that has gone QUIET, and only then.
///
/// One timer armed for the whole read is a TOTAL budget: it ends a transfer
/// that is making progress, which is what the dial's own figure was doing to
/// every download and every second reply until fix round 1 (R2). This watchdog
/// is rearmed from its own firing instead — when it fires it asks how long ago
/// the last chunk arrived and either reschedules for the remainder or gives up
/// — so a chunk costs one clock write rather than a timer, however many
/// chunks a transfer has.
///
/// `onIdle` runs on the event loop, at most once. `stop()` cancels the pending
/// timer, so a finished read leaves nothing scheduled.
///
/// **Both halves of its time are injectable, and that is one decision, not
/// two.** The timer comes from `loop`, which a test can drive with an
/// `EmbeddedEventLoop`; the elapsed span comes from `now`. Passing only the
/// loop gives a watchdog that can never fire under test, because advancing
/// the loop's manual time runs the tick while the real clock has barely
/// moved, so every tick measures a span of roughly zero and REARMS —
/// measured 2026-11-06 on exactly that half-injected shape: the "progress
/// rearms it" half passed and the "silence fires it" half failed, which is
/// the positive check beside the negative one earning its keep, since "did
/// not fire" is also what a watchdog that cannot fire looks like. Half an
/// injectable clock is worse than none, because the half still reading the
/// real clock is the half an assertion rests on.
final class FTPIdleWatchdog: Sendable {
    private struct Inner {
        var lastProgress: ContinuousClock.Instant
        var pending: Scheduled<Void>?
        var stopped = false
    }

    private enum Tick {
        case stop
        case fire
        case again(TimeAmount)
    }

    private let bound: TimeAmount
    private let loop: any EventLoop
    private let now: @Sendable () -> ContinuousClock.Instant
    private let onIdle: @Sendable () -> Void
    private let state: Mutex<Inner>

    /// - Parameter now: where "how long ago was the last chunk" is read from.
    ///   Defaults to the real clock, so no production call site names it; a
    ///   test passes a clock it advances itself, together with an
    ///   `EmbeddedEventLoop` for `loop`.
    init(
        bound: TimeAmount, loop: any EventLoop,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        onIdle: @escaping @Sendable () -> Void
    ) {
        self.bound = bound
        self.loop = loop
        self.now = now
        self.onIdle = onIdle
        self.state = Mutex(Inner(lastProgress: now()))
    }

    func start() {
        arm(bound)
    }

    func noteProgress() {
        let instant = now()
        state.withLock { $0.lastProgress = instant }
    }

    func stop() {
        let pending = state.withLock { inner -> Scheduled<Void>? in
            inner.stopped = true
            let scheduled = inner.pending
            inner.pending = nil
            return scheduled
        }
        pending?.cancel()
    }

    private func arm(_ delay: TimeAmount) {
        let scheduled = loop.scheduleTask(in: delay) { [self] in
            switch tick() {
            case .stop: break
            case .fire: onIdle()
            case .again(let remaining): arm(remaining)
            }
        }
        // A `stop()` that ran between building the timer and storing it would
        // otherwise leave this one scheduled with nobody holding it.
        let cancelled = state.withLock { inner -> Bool in
            guard !inner.stopped else { return true }
            inner.pending = scheduled
            return false
        }
        if cancelled { scheduled.cancel() }
    }

    private func tick() -> Tick {
        let instant = now()
        return state.withLock { inner in
            guard !inner.stopped else { return .stop }
            inner.pending = nil
            let quiet = instant - inner.lastProgress
            guard quiet < Duration(bound) else {
                inner.stopped = true
                return .fire
            }
            return .again(TimeAmount(Duration(bound) - quiet))
        }
    }
}

extension Duration {
    /// A `TimeAmount` as a `Duration`, so the watchdog can do its arithmetic
    /// in one unit.
    fileprivate init(_ amount: TimeAmount) {
        self = .nanoseconds(amount.nanoseconds)
    }
}

extension TimeAmount {
    /// The conversion `FTPControlConnection.timeAmount(_:)` performs, reachable
    /// from the watchdog, which is not inside that type.
    fileprivate init(_ duration: Duration) {
        let components = duration.components
        let nanoseconds =
            components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
        self = .nanoseconds(max(0, nanoseconds))
    }
}

/// The inbound end of a channel, read by an actor.
///
/// A class because an actor cannot call a mutating `async` method on a stored
/// property, and `@unchecked Sendable` because the iterator is the only
/// mutable state and every read is serialised by the owner: on a control
/// connection by the command turn, on a data connection by its being one
/// actor's own stream. An `AsyncStream` has a single consumer, and two
/// overlapping `next()` calls on one iterator are undefined behaviour that
/// stays silent, so `reader` turns a violation into a named trap.
final class FTPLineSource: @unchecked Sendable {
    private var iterator: AsyncStream<ByteBuffer>.Iterator
    private let reader = Mutex(false)

    init(_ stream: AsyncStream<ByteBuffer>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> ByteBuffer? {
        let overlapped = reader.withLock { busy -> Bool in
            let was = busy
            busy = true
            return was
        }
        precondition(!overlapped, "two reads overlapped on one FTP channel's stream")
        defer { reader.withLock { $0 = false } }
        return await iterator.next()
    }
}

/// What a channel's tail learns and the awaiting side needs: whether the TLS
/// handshake completed, and why a stream ended.
///
/// Written from event-loop callbacks, read by an actor. Without the recorded
/// end, a bound that fired and a peer that closed are the same empty stream
/// from where the read is waiting.
final class FTPChannelEvents: Sendable {
    enum End: Sendable, Equatable {
        case none
        case closed
        case timedOut
    }

    private let end_ = Mutex(End.none)
    private let handshakeOutcome = Mutex<Bool?>(nil)
    private let handshakeSignal = AsyncSignal()

    var end: End { end_.withLock { $0 } }

    /// First end wins: the one that stopped the stream explains the ones that
    /// follow it.
    func noteEnd(_ reason: End) {
        end_.withLock { if $0 == .none { $0 = reason } }
    }

    /// Settles the handshake once, with whether it completed.
    func noteHandshake(_ completed: Bool) {
        let first = handshakeOutcome.withLock { outcome -> Bool in
            guard outcome == nil else { return false }
            outcome = completed
            return true
        }
        if first { handshakeSignal.signal() }
    }

    /// Whether the handshake completed, or `nil` if `timeout` elapsed or the
    /// waiting task was cancelled before it settled.
    func awaitHandshake(timeout: Duration) async -> Bool? {
        guard await handshakeSignal.wait(timeout: timeout) == .signalled else { return nil }
        return handshakeOutcome.withLock { $0 }
    }
}

/// Whether a data connection's full handshake presented certificate material
/// that is not its control connection's — recorded in the verification
/// callback, read after the handshake has failed, so the refusal can say
/// WHICH rule it was.
final class FTPDataTrustOutcome: Sendable {
    private let state = Mutex(false)

    var differs: Bool { state.withLock { $0 } }

    func noteDiffers() {
        state.withLock { $0 = true }
    }
}

/// Hands whatever reaches the end of the pipeline to a stream, and reports
/// the TLS handshake and the end of the connection.
final class FTPChannelSink: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let deliver: AsyncStream<ByteBuffer>.Continuation
    private let events: FTPChannelEvents

    init(deliver: AsyncStream<ByteBuffer>.Continuation, events: FTPChannelEvents) {
        self.deliver = deliver
        self.events = events
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        deliver.yield(unwrapInboundIn(data))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tls = event as? TLSUserEvent, case .handshakeCompleted = tls {
            events.noteHandshake(true)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        events.noteHandshake(false)
        events.noteEnd(.closed)
        deliver.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        events.noteHandshake(false)
        events.noteEnd(.closed)
        deliver.finish()
        context.close(promise: nil)
    }
}

/// Splits the control stream into lines at LF and drops the CR before it.
///
/// Bytes, not text: the terminator is `0x0D 0x0A` on the wire, and a decoder
/// written over `String` would have to decode a partial line to find its end.
/// A trailing partial line at end of input is discarded, which is what a
/// server does with a command that never ended.
struct FTPLineDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    mutating func decode(
        context: ChannelHandlerContext, buffer: inout ByteBuffer
    ) throws -> DecodingState {
        guard let lineFeed = buffer.readableBytesView.firstIndex(of: 0x0A) else {
            return .needMoreData
        }
        let length = lineFeed - buffer.readerIndex
        guard var line = buffer.readSlice(length: length) else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: 1)
        if line.readableBytesView.last == 0x0D { line.moveWriterIndex(to: line.writerIndex - 1) }
        context.fireChannelRead(wrapInboundOut(line))
        return .continue
    }

    mutating func decodeLast(
        context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool
    ) throws -> DecodingState {
        .needMoreData
    }
}

// MARK: - The trust decision

/// A verification callback that may cross a concurrency boundary.
///
/// `NIOSSLCustomVerificationCallback` is a plain function type with no
/// `@Sendable` on it, and a `channelInitializer` is `@Sendable`, so a bare
/// callback cannot be handed to one. The two callbacks built in this file
/// capture only `Sendable` state — `FTPTrustDecision` and
/// `FTPDataTrustOutcome`, both `Sendable` classes whose own state is behind a
/// `Mutex` — which is what makes this box sound and not merely sufficient to
/// compile.
struct FTPVerification: @unchecked Sendable {
    let callback: NIOSSLCustomVerificationCallback
}

/// The control connection's certificate decision, and the certificate it
/// accepted.
///
/// A class rather than actor state: the verification callback runs on the
/// event loop, in the middle of a handshake, and the actor reads the result
/// afterwards. The decision itself is taken OFF the event loop — it may ask a
/// person — because NIOSSL forbids re-entering its handler from the callback.
final class FTPTrustDecision: Sendable {
    private let host: String
    private let port: Int
    private let decider: CertificateDecider
    private let trustStore: TrustedCertificateStore?

    private struct Inner {
        var acceptedDER: [UInt8]?
        var failure: FTPConnectionFailure?
    }

    private let state = Mutex(Inner())

    private static let logger = Logger(subsystem: "dev.noix.macscp", category: "FTPTrustDecision")

    init(
        host: String, port: Int, decider: CertificateDecider,
        trustStore: TrustedCertificateStore?
    ) {
        self.host = host
        self.port = port
        self.decider = decider
        self.trustStore = trustStore
    }

    /// The DER of the certificate this connection's handshake accepted —
    /// what the peer PRESENTED, taken from the verification callback's own
    /// argument. Ruling T5.1 compares a data connection's full handshake
    /// against exactly these bytes.
    var acceptedCertificateDER: [UInt8]? { state.withLock { $0.acceptedDER } }

    /// Why the decision refused, when it did.
    var failure: FTPConnectionFailure? { state.withLock { $0.failure } }

    var verification: FTPVerification {
        FTPVerification { [self] certificates, promise in
            guard let leaf = certificates.first, let der = try? leaf.toDERBytes() else {
                record(.certificateRejected)
                promise.succeed(.failed)
                return
            }
            let notAfter = leaf.notValidAfter
            let chain = certificates.compactMap { try? $0.toDERBytes() }
            Task { [self] in
                // A DIAGNOSTIC, before the decision and reaching no part of
                // it: `reportSystemTrust` returns nothing, so there is no
                // value for the line below to read. See its own comment.
                reportSystemTrust(chain: chain)
                let accepted = await decide(der: der, notAfter: notAfter)
                promise.succeed(accepted ? .certificateVerified : .failed)
            }
        }
    }


    /// TOFU, the same three outcomes WebDAV's path has: a remembered and
    /// identical certificate is accepted in silence, a remembered and
    /// different one is a hard stop that asks nobody, and an unknown one is
    /// put to the decider and remembered if it is accepted.
    private func decide(der: [UInt8], notAfter: time_t) async -> Bool {
        let summary = Self.subjectSummary(of: der)
        let candidate = ServerCertificateCandidate(
            host: host, port: port, derBase64: Data(der).base64EncodedString(),
            subject: summary, issuer: summary,
            notAfter: notAfter > 0 ? Date(timeIntervalSince1970: TimeInterval(notAfter)) : nil)

        let known: TrustedCertificate?
        if let trustStore {
            do {
                known = try trustStore.find(host: host, port: port)
            } catch {
                // Fail closed. Treating an unreadable store as "unknown"
                // would re-TOFU and overwrite a remembered certificate, and
                // it is not a user refusal — keep the two distinguishable.
                record(.trustStoreUnreadable)
                return false
            }
        } else {
            known = nil
        }

        switch ServerCertificateValidation.evaluate(candidate: candidate, known: known) {
        case .accept:
            accept(der)
            return true
        case .mismatch:
            record(.certificateMismatch)
            return false
        case .askUser:
            guard await decider(candidate) else {
                record(.certificateRejected)
                return false
            }
            if let trustStore {
                do {
                    try trustStore.upsert(
                        TrustedCertificate(
                            host: host, port: port, derBase64: candidate.derBase64,
                            subject: candidate.subject, issuer: candidate.issuer,
                            notAfter: candidate.notAfter))
                } catch {
                    // Recorded in the log and not thrown: the handshake
                    // continues with the certificate the user just approved,
                    // which is exactly as trustworthy as they said it was.
                    // What is lost is TOFU for this host — nothing was
                    // pinned, so the hard stop above can never fire for a
                    // substituted certificate here. Too quiet to leave to a
                    // `try?`. The host is named `.public` so the line is
                    // findable; the error's own text names the store's path
                    // and with it the account name, so it stays `.private`.
                    Self.logger.error(
                        """
                        trusted-certificate store not writable; the accepted certificate for \
                        \(self.host, privacy: .public):\(self.port, privacy: .public) was not \
                        pinned and this host stays unpinned: \
                        \(error.localizedDescription, privacy: .private)
                        """)
                }
            }
            accept(der)
            return true
        }
    }

    /// Writes ONE log line saying what the system trust store would have made
    /// of this chain, and influences nothing.
    ///
    /// **Why it exists.** This connection's trust decision is TOFU: an
    /// unknown certificate is put to a person who compares a fingerprint, and
    /// the chain is never evaluated against the system's anchors. That is the
    /// design, and it is right — a NAS with a self-signed certificate is the
    /// common case and a chain check would refuse it. But it leaves nobody
    /// able to answer the question a user actually asks, which is "my browser
    /// trusts this server, why am I being asked?", and the answer is usually a
    /// missing intermediate the server did not send. This line answers it.
    ///
    /// **Why it cannot reach the decision, structurally rather than by
    /// discipline.** It returns `Void`. There is no value for
    /// `verification`'s `Task` to read, no stored property it writes, and
    /// `decide(der:notAfter:)` does not take it as an argument — so the three
    /// TOFU outcomes are exactly what they were. `theTrustDiagnosticIsLogOnly`
    /// is the guard that says so, and the behavioural proof is
    /// `aPinnedCertificateThatChangedIsAHardStopWithNoPrompt`, whose second
    /// half dials a server whose SELF-SIGNED certificate this function
    /// reports as untrusted and is `.connected` on consent.
    ///
    /// **Network fetching is turned off.** `SecTrustEvaluateWithError` will
    /// otherwise fetch missing intermediates and CRL/OCSP responses, which on
    /// a dial path is an unbounded wait on a third party for a line nobody is
    /// blocked on. `SecTrustSetNetworkFetchAllowed(_:false)` makes it a local
    /// evaluation; the cost is that a chain completable only by fetching
    /// reads as untrusted, which is the honest answer for a server that did
    /// not send its intermediate and is exactly the case the line is for.
    ///
    /// **What reaches the log.** The verdict, and the OSStatus-style code of
    /// the `CFError` when there is one — both `.public`, because neither is
    /// about this peer. Never the error's localized text, which embeds the
    /// certificate's subject and so the host; never a fingerprint; never the
    /// DER. The host and port are already in this connection's other log
    /// lines and are not repeated here, because this line's subject is the
    /// chain and not the endpoint.
    private func reportSystemTrust(chain: [[UInt8]]) {
        guard !chain.isEmpty else { return }
        let certificates = chain.compactMap {
            SecCertificateCreateWithData(nil, Data($0) as CFData)
        }
        guard certificates.count == chain.count else { return }
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, host as CFString)
        guard SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust) == errSecSuccess,
            let trust
        else { return }
        _ = SecTrustSetNetworkFetchAllowed(trust, false)
        var failure: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &failure)
        let code = failure.map { String(CFErrorGetCode($0)) } ?? "none"
        Self.logger.info(
            """
            system trust store verdict for this FTPS chain (diagnostic only, \
            it decides nothing): trusted=\(trusted, privacy: .public) \
            code=\(code, privacy: .public) depth=\(chain.count, privacy: .public)
            """)
    }

    private func accept(_ der: [UInt8]) {
        state.withLock { $0.acceptedDER = der }
    }

    private func record(_ failure: FTPConnectionFailure) {
        state.withLock { if $0.failure == nil { $0.failure = failure } }
    }

    /// The certificate's subject, as the prompt shows it.
    ///
    /// Through `SecCertificate`, as `WebDAVSessionDelegate.candidate(from:…)`
    /// does, and with the issuer set to the same text for the same reason:
    /// `NIOSSLCertificate` exposes no name accessors, and the fingerprint is
    /// what the decision rests on either way.
    private static func subjectSummary(of der: [UInt8]) -> String {
        guard let certificate = SecCertificateCreateWithData(nil, Data(der) as CFData),
            let summary = SecCertificateCopySubjectSummary(certificate) as String?
        else { return "?" }
        return summary
    }
}
