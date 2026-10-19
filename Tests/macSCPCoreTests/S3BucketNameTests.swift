import Foundation
import Testing
@testable import macSCPCore

/// macSCP's own bucket-name check (`S3BucketName.problem(with:)`): the rules
/// S3 states for a bucket name, applied before a create request exists.
///
/// The check is macSCP's because the store is not the gate: a store that
/// speaks S3 may accept a name AWS refuses (the Docker rig's store is lenient
/// about CORS methods in the same way, `CORSRule.validate()`), and a refusal
/// should not wait for the first request. The refusals and the acceptances
/// sit in one file on purpose; each list is the control for the other.
@Suite("S3 bucket names")
struct S3BucketNameTests {
    // MARK: - Refused

    @Test(arguments: [
        ("ab", BucketNameProblem.tooShort),
        ("My-Bucket", .uppercase),
        ("my_bucket", .invalidCharacter("_")),
        ("192.168.0.1", .looksLikeAnIPAddress),
        ("-leading", .badEdge),
        ("trailing-", .badEdge),
    ])
    func aNameSThreeWouldRejectIsRefusedHere(name: String, expected: BucketNameProblem) {
        #expect(S3BucketName.problem(with: name) == expected)
    }

    /// The rest of each rule's territory: the boundaries of the length, both
    /// ends of the name for each of the edge characters, and characters that
    /// are neither letter, digit, hyphen nor dot.
    @Test(arguments: [
        ("", BucketNameProblem.tooShort),
        ("a", .tooShort),
        (String(repeating: "a", count: 64), .tooLong),
        (String(repeating: "a", count: 200), .tooLong),
        ("UPPER", .uppercase),
        ("mixedCase", .uppercase),
        ("has space", .invalidCharacter(" ")),
        ("slash/inside", .invalidCharacter("/")),
        ("caf\u{E9}-bucket", .invalidCharacter("\u{E9}")),
        ("under_score_and_second_", .invalidCharacter("_")),
        (".leading-dot", .badEdge),
        ("trailing-dot.", .badEdge),
        ("-.-", .badEdge),
        ("0.0.0.0", .looksLikeAnIPAddress),
        ("255.255.255.255", .looksLikeAnIPAddress),
        ("999.999.999.999", .looksLikeAnIPAddress),
    ])
    func theBoundariesOfEachRuleAreRefused(name: String, expected: BucketNameProblem) {
        #expect(S3BucketName.problem(with: name) == expected)
    }

    /// When a name breaks more than one rule, the answer is the first of
    /// these, in this order: length, uppercase, any other character, the
    /// edges, the address form. Pinned so a UI that shows ONE problem shows
    /// the same one every time; uppercase before the character check because
    /// lowercasing is the one-step fix.
    @Test(arguments: [
        ("A", BucketNameProblem.tooShort),
        ("Ab_", .uppercase),
        ("_b-Ab", .uppercase),
        ("_ab", .invalidCharacter("_")),
        ("-a_b", .invalidCharacter("_")),
    ])
    func whenSeveralRulesAreBrokenTheFirstInTheDocumentedOrderIsReported(
        name: String, expected: BucketNameProblem
    ) {
        #expect(S3BucketName.problem(with: name) == expected)
    }

    // MARK: - Accepted

    /// The positive control for the refusals above: a refusal list with no
    /// acceptance list beside it cannot be shown to refuse only what it
    /// should.
    @Test(arguments: ["macscp-seed", "a-b-c", "bucket123", String(repeating: "a", count: 63)])
    func aValidNamePasses(name: String) {
        #expect(S3BucketName.problem(with: name) == nil)
    }

    /// Names that sit right beside a refusal: the shortest and longest legal
    /// lengths, dots inside a name, a digit at either edge, and strings that
    /// resemble an address without being one. A rule written too wide
    /// refuses one of these.
    ///
    /// `a-.-b` and `1.2.3.-4` are on the list on purpose and are NOT claims
    /// that AWS accepts them: AWS refuses a dot beside a hyphen. They
    /// are names this layer deliberately does not check (see the "Not
    /// checked" paragraph of `S3BucketName`), so the store is left to
    /// refuse them, and the list pins that the subset implemented here
    /// is exactly the subset documented.
    @Test(arguments: [
        "abc", "a1b", "123", "1a2",
        "my.bucket.name", "a.b", "a-.-b",
        String(repeating: "a", count: 62),
        "192.168.0", "192.168.0.1.2", "192.168.0.a", "a.168.0.1", "192.168.0.1a", "1.2.3.-4",
        "0000", "12345",
    ])
    func aNameBesideARefusalStillPasses(name: String) {
        #expect(S3BucketName.problem(with: name) == nil)
    }
}
