import Foundation

/// The universal half of the connection diagnosis, plus the seam the
/// protocols fill (design §§2–3).
///
/// Runs, in order and each under its own deadline: name resolution, one TCP
/// connection attempt per resolved address, the backend's own dial, and then
/// whatever the backend contributes. Nothing here asks which protocol it is
/// looking at — the endpoint, the dial and the contributions all arrive
/// through `BackendDescriptor`, which is what keeps a fourth backend from
/// having to be mentioned in this file at all.
///
/// The first three steps touch no credential. The dial and the contributions
/// may, and only through the source the connect path itself uses
/// (`DiagnosticContext.secret()`); no step ever writes one into a detail line
/// — pinned by `theSSHDialNeverPutsTheSecretInTheReport`.
///
/// Cancellable through the calling task: `run()` returns the report with the
/// steps that finished before the cancellation, and never a half-measured
/// row.
public actor ConnectionDiagnostics {
    private let descriptor: BackendDescriptor
    private let values: FieldValues
    private let secrets: (any SecretSource)?
    private let sessionID: UUID?
    private let stepTimeout: Duration
    private let appVersion: String

    /// - Parameters:
    ///   - secrets: where a contribution's credential comes from — the same
    ///     source the connect path resolves through. `nil` runs the universal
    ///     half and skips whatever needs a secret.
    ///   - sessionID: which session that source answers for. `SecretSource`
    ///     is keyed by session, so a source without this cannot answer and
    ///     the dial is skipped rather than dialled without a password.
    ///   - appVersion: what the report's build line says. Passed in because
    ///     Core does not read `Bundle.main` — the App owns that
    ///     (`SettingsView`), and Core carries no bundle assumption.
    public init(
        descriptor: BackendDescriptor,
        values: FieldValues,
        secrets: (any SecretSource)?,
        sessionID: UUID? = nil,
        stepTimeout: Duration = .seconds(5),
        appVersion: String = "unknown"
    ) {
        self.descriptor = descriptor
        self.values = values
        self.secrets = secrets
        self.sessionID = sessionID
        self.stepTimeout = stepTimeout
        self.appVersion = appVersion
    }

    public func run() async -> DiagnosticReport {
        guard let endpoint = descriptor.endpoint(values) else {
            // Not `failed`: nothing was measured and nothing is wrong with
            // the server. The form is incomplete, and the row has to say that
            // rather than report a lookup that never happened.
            let timer = Self.timer(for: DiagnosticStepID.resolve)
            return DiagnosticReport(
                endpoint: Endpoint(host: "", port: 0),
                steps: [timer.finish(.unavailable("this session names no host"), "")],
                appVersion: appVersion)
        }

        var steps: [DiagnosticStep] = []
        func report() -> DiagnosticReport {
            DiagnosticReport(endpoint: endpoint, steps: steps, appVersion: appVersion)
        }

        guard !Task.isCancelled else { return report() }
        let (resolveStep, addresses) = await resolve(endpoint)
        guard !Task.isCancelled else { return report() }
        steps.append(resolveStep)

        guard !Task.isCancelled else { return report() }
        let tcpStep = await ping(addresses, port: endpoint.port)
        guard !Task.isCancelled else { return report() }
        steps.append(tcpStep)

        for contribution in ([descriptor.dial].compactMap { $0 } + descriptor.diagnostics) {
            guard !Task.isCancelled else { return report() }
            let step = await bounded(contribution)
            guard !Task.isCancelled else { return report() }
            steps.append(step)
        }
        return report()
    }

    // MARK: - The universal steps

    private func resolve(_ endpoint: Endpoint) async -> (DiagnosticStep, [ResolvedAddress]) {
        let timer = Self.timer(for: DiagnosticStepID.resolve)
        let outcome = await HostResolver.resolve(
            host: endpoint.host, port: endpoint.port, timeout: stepTimeout)
        switch outcome {
        case .resolved(let addresses):
            let detail = addresses
                .map { "\($0.family.rawValue) \($0.text)" }
                .joined(separator: ", ")
            return (timer.finish(.ok, detail), addresses)
        case .failed(let reason):
            return (timer.finish(.failed(reason), ""), [])
        case .timedOut:
            return (timer.finish(.timedOut, ""), [])
        }
    }

    private func ping(_ addresses: [ResolvedAddress], port: Int) async -> DiagnosticStep {
        let timer = Self.timer(for: DiagnosticStepID.tcp)
        guard !addresses.isEmpty else {
            return timer.finish(.skipped("nothing resolved to probe"), "")
        }
        let results = await TCPPing.probeAll(addresses: addresses, timeout: stepTimeout)
        let detail = results.map { result -> String in
            let target = Endpoint(host: result.address.text, port: port).text
            guard let elapsed = result.outcome.elapsed else {
                return "\(target) \(result.outcome.label)"
            }
            return "\(target) \(result.outcome.label) in \(DurationText.milliseconds(elapsed))"
        }.joined(separator: "; ")

        // The first address that ACCEPTS decides the step: a host with an
        // AAAA nothing listens on and an A that answers is a working
        // connection, and a row that reported the IPv6 refusal as the verdict
        // would send the user after a problem they do not have.
        if results.contains(where: { if case .accepted = $0.outcome { return true } else { return false } }) {
            return timer.finish(.ok, detail)
        }
        if results.contains(where: { if case .refused = $0.outcome { return true } else { return false } }) {
            return timer.finish(.failed("refused"), detail)
        }
        if results.allSatisfy({ $0.outcome == .timedOut }) {
            return timer.finish(.timedOut, detail)
        }
        let firstFailure = results.compactMap { result -> String? in
            if case .failed(let reason) = result.outcome { return reason }
            return nil
        }.first
        return timer.finish(.failed(firstFailure ?? "no address accepted"), detail)
    }

    // MARK: - The seam

    /// Runs one contribution and holds it to the step timeout from outside.
    ///
    /// The contribution is told the same budget (`DiagnosticContext.timeout`)
    /// so its own transport can stop itself; this race is what keeps a probe
    /// that ignores its budget from stopping the whole diagnosis. A step the
    /// deadline wins is reported `timedOut` with the elapsed time measured
    /// here, never with whatever the abandoned probe would have said.
    private func bounded(_ contribution: DiagnosticContribution) async -> DiagnosticStep {
        let timer = DiagnosticStepTimer(id: contribution.id, titleKey: contribution.titleKey)
        let context = DiagnosticContext(
            secrets: secrets, sessionID: sessionID, timeout: stepTimeout)
        let values = self.values
        let timeout = stepTimeout
        let finished = await withTaskGroup(of: DiagnosticStep?.self) { group in
            group.addTask { await contribution.run(values, context) }
            group.addTask {
                // A cancelled sleep also returns nil, and the caller of
                // `run()` re-reads `Task.isCancelled` — so a cancellation is
                // never mistaken for a timeout in the report, because a
                // cancelled step is not appended at all.
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return finished ?? timer.finish(.timedOut, "")
    }

    private static func timer(for id: String) -> DiagnosticStepTimer {
        DiagnosticStepTimer(id: id, titleKey: DiagnosticStepID.titleKey(for: id))
    }
}
