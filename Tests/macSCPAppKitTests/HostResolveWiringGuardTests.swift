import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// Guards the wiring of "Resolve…" beside the connection form's host field
/// (the BACKLOG row "Offer to resolve an entered host name to its IP",
/// 2026-09-19): that the form draws it beside the target host of an SSH form
/// and nowhere else, that the line under the field comes from the same
/// model, and that nothing on this path writes a known host.
///
/// What choosing an address WRITES to the form is `HostResolveModelTests`'
/// claim, tested on values; this suite reads source, because no view is
/// rendered in a test. Code is read with comments and string literals
/// blanked (`SwiftSource.blankingCommentsAndStrings`), so a doc comment that
/// talks about known hosts — the model's does, to say why it writes none —
/// is not mistaken for code that touches them.
///
/// Type names are read off the types (`String(describing:)`) rather than
/// spelled, so a rename breaks the positive checks loudly instead of
/// leaving a negative one pointed at nothing.
///
/// ## The negative checks have positive partners
///
/// CLAUDE.md, "Guards that name what they watch". The known-hosts scan reads
/// four spans; a positive check on each proves the span is the path — it
/// holds the lookup, the choice, the control — before the negative one says
/// what it lacks. The jump section's negative check is paired with one that
/// proves the scanned span draws the jump host's own field.
@Suite("Host resolve wiring")
struct HostResolveWiringGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let formPath = "Sources/MacSCPAppKit/ConnectionFormView.swift"
    private static let schemaPath = "Sources/MacSCPAppKit/SchemaFormView.swift"
    private static let modelPath =
        "Sources/MacSCPAppKit/Presentation/\(String(describing: HostResolveModel.self)).swift"
    private static let controlPath =
        "Sources/MacSCPAppKit/\(String(describing: HostResolveControl.self)).swift"
    private static let lookupPath =
        "Sources/macSCPCore/Diagnostics/\(String(describing: HostAddressLookup.self)).swift"

    private static let control = String(describing: HostResolveControl.self)
    private static let model = String(describing: HostResolveModel.self)

    /// No trailing `{` — `declarationBodyRange` opens at the first brace
    /// after the declaration text.
    private static let accessoryDeclaration = "private func fieldAccessory("
    private static let footnoteDeclaration = "private func fieldFootnote("
    private static let jumpDeclaration = "private var sshJumpSection: some View"
    private static let chooseDeclaration = "func choose("

    private static func code(_ relativePath: String) throws -> String {
        try SourceCorpus.code(of: repoRoot.appendingPathComponent(relativePath))
    }

    private static func body(of declaration: String, in source: String) throws -> String {
        TransferQueueBarCancelGuardTests.slice(
            try TransferQueueBarCancelGuardTests.declarationBodyRange(of: declaration, in: source),
            of: source)
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // MARK: - Where the action is drawn

    /// The form hands `SchemaFormView` its accessory, and the accessory is
    /// the control — for the host field of a kind the model offers it for,
    /// and for nothing else.
    @Test func theFormDrawsTheControlBesideTheHostFieldOfAnOfferingKindOnly() throws {
        let form = try Self.code(Self.formPath)
        let arguments = try DiagnosticsDoorsGuardTests.argumentSpan(
            after: "SchemaFormView(", in: form, occurrence: 1)
        #expect(arguments.contains("accessory: fieldAccessory"), """
            ConnectionFormView no longer hands SchemaFormView its accessory — \
            "Resolve…" is drawn nowhere.
            """)
        #expect(Self.occurrences(of: "SchemaFormView(", in: form) == 1, """
            ConnectionFormView builds more than one SchemaFormView — re-point \
            this guard at every one of them.
            """)

        let accessory = try Self.body(of: Self.accessoryDeclaration, in: form)
        #expect(accessory.contains("\(Self.model).isOffered(for: viewModel.kind)"), """
            fieldAccessory no longer asks \(Self.model).isOffered(for:) — the \
            action would be drawn for S3 and WebDAV too, whose TLS certificate \
            is checked against the name.
            """)
        #expect(accessory.contains("SSHField.host.rawValue"), """
            fieldAccessory no longer names the host field through the schema \
            enum — the control would sit beside another field, or every one.
            """)
        #expect(accessory.contains("\(Self.control)("))
    }

    /// `SchemaFormView` asks for an accessory once — for a top-level field —
    /// and never for a group's leaves.
    @Test func theRendererAsksForAnAccessoryForTopLevelFieldsOnly() throws {
        let schema = try Self.code(Self.schemaPath)
        #expect(Self.occurrences(of: "accessory?(field)", in: schema) == 1, """
            SchemaFormView asks for a field's accessory \
            \(Self.occurrences(of: "accessory?(field)", in: schema)) time(s), expected once — \
            in the top-level row.
            """)
        #expect(Self.occurrences(of: "accessory?(", in: schema) == 1, """
            SchemaFormView asks for an accessory somewhere other than the \
            top-level row — a group's leaves would get one.
            """)
    }

    /// The jump host's row is drawn by hand and carries no action: the task
    /// covers the target host only. Positive first: the span scanned is the
    /// one that draws the jump host's field.
    @Test func theJumpHostRowCarriesNoResolveAction() throws {
        let form = try Self.code(Self.formPath)
        let jump = try Self.body(of: Self.jumpDeclaration, in: form)
        #expect(jump.contains("viewModel.jumpHost"), """
            sshJumpSection no longer binds the jump host's field — the \
            negative check below would be reading a span without it.
            """)
        #expect(!jump.contains("\(Self.control)("), """
            sshJumpSection draws \(Self.control) — the jump host got the \
            action, which this task leaves out.
            """)
        #expect(!jump.contains(Self.model), """
            sshJumpSection reads \(Self.model).
            """)
    }

    /// The line under the host field is the same model's.
    @Test func theLineUnderTheHostFieldComesFromTheModel() throws {
        let form = try Self.code(Self.formPath)
        let footnote = try Self.body(of: Self.footnoteDeclaration, in: form)
        #expect(footnote.contains("\(Self.model).footnote(for: hostResolve.presentation(forHost:"))
        #expect(footnote.contains("SSHField.host.rawValue"))
        #expect(footnote.contains("\(Self.model).isOffered(for: viewModel.kind)"))
    }

    /// The control resolves and chooses through the model — the two calls a
    /// click reaches.
    @Test func theControlResolvesAndChoosesThroughTheModel() throws {
        let control = try Self.code(Self.controlPath)
        #expect(control.contains("model.resolve(host)"))
        #expect(control.contains("model.choose(address, in: form)"))
        #expect(control.contains("HostAddressLookup.isResolvable(host)"))
    }

    // MARK: - No known-hosts write on this path

    /// Stems of every name through which a known host is written or a key
    /// is trusted, derived from the types that own them: the store, and the
    /// form's first-connection prompt (`resolveHostKeyPrompt(trust:)` is
    /// how a key becomes trusted from the form).
    private static let forbiddenStems = ["knownhost", "hostkey", "trust"]

    /// The stems name what they are meant to: each type this suite forbids
    /// is caught by one of them, so a rename of either type breaks this
    /// check before it can quietly empty the scan below.
    @Test func theForbiddenStemsCatchTheStoreAndThePrompt() {
        for type in [
            String(describing: KnownHostsStore.self),
            String(describing: ConnectionViewModel.HostKeyPrompt.self),
        ] {
            #expect(Self.forbiddenStems.contains { type.lowercased().contains($0) }, """
                no forbidden stem catches \(type) — the known-hosts scan \
                would pass over code that uses it.
                """)
        }
    }

    /// The spans on the path from the click to the host field: the Core
    /// lookup, the model, the control and the form's accessory closure —
    /// each with an anchor that proves it is that span.
    private static func pathSpans() throws -> [(name: String, code: String, anchor: String)] {
        let form = try code(formPath)
        return [
            (lookupPath, try code(lookupPath), "HostResolver.resolve("),
            (modelPath, try code(modelPath), "form.host = address"),
            (controlPath, try code(controlPath), "model.choose("),
            ("fieldAccessory", try body(of: accessoryDeclaration, in: form), "\(control)("),
        ]
    }

    /// Positive partner of the scan below: every span is found and holds
    /// its anchor, so a pass below is "the path is there and names no known
    /// host", never "the scan read nothing".
    @Test func everySpanOnThePathIsThere() throws {
        for span in try Self.pathSpans() {
            #expect(span.code.contains(span.anchor), """
                \(span.name) no longer holds `\(span.anchor)` — it is not the \
                span on the resolve path any more, and the known-hosts scan \
                over it proves nothing.
                """)
        }
    }

    /// Nothing on the path writes, reads or trusts a known host. Choosing an
    /// address changes the host text, and the next connect asks for consent
    /// the ordinary way; copying the name's entry to the address would be an
    /// accept path.
    @Test func noSpanOnThePathTouchesKnownHosts() throws {
        for span in try Self.pathSpans() {
            let lowered = span.code.lowercased()
            for stem in Self.forbiddenStems {
                #expect(!lowered.contains(stem), """
                    \(span.name) mentions `\(stem)` in code — the resolve path \
                    touches known hosts or host-key trust.
                    """)
            }
        }
    }

    /// Choosing writes the host field and no other property of the form.
    /// Positive: the one write is there. Negative: no other assignment to
    /// the form.
    @Test func choosingWritesTheHostAndNothingElse() throws {
        let choose = try Self.body(of: Self.chooseDeclaration, in: try Self.code(Self.modelPath))
        #expect(Self.occurrences(of: "form.host = ", in: choose) == 1)
        #expect(Self.occurrences(of: "form.", in: choose) == 1, """
            choose(_:in:) touches the form more than once — it writes, or \
            calls, something besides the host.
            """)
    }

    // MARK: - The scans react

    /// A known-hosts write planted in a span is caught, and a comment that
    /// talks about known hosts is not.
    @Test func theScanCatchesAPlantedWriteAndNotAComment() throws {
        let planted = try SwiftSource.blankingCommentsAndStrings("""
            func choose(_ address: String, in form: ConnectionViewModel) {
                // Known hosts are keyed by host and port; nothing is trusted here.
                form.host = address
                try? KnownHostsStore(directory: SessionStore.defaultDirectory).add(entry)
            }
            """)
        let commentOnly = try SwiftSource.blankingCommentsAndStrings("""
            func choose(_ address: String, in form: ConnectionViewModel) {
                // Known hosts are keyed by host and port; nothing is trusted here.
                form.host = address
            }
            """)
        #expect(Self.forbiddenStems.contains { planted.lowercased().contains($0) })
        #expect(!Self.forbiddenStems.contains { commentOnly.lowercased().contains($0) })
    }

    /// An accessory planted on a group's leaves is counted.
    @Test func theRendererScanCatchesAnAccessoryOnAGroupLeaf() {
        let planted = """
            leafRow(label: a, kind: leafKind, binding: binding(field.id),
                    accessory: accessory?(field))
            leafRow(label: b, kind: leaf.kind, binding: binding(field.id, leaf.id),
                    accessory: accessory?(field))
            """
        #expect(Self.occurrences(of: "accessory?(", in: planted) == 2)
    }
}
