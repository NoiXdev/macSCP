import Foundation
import Synchronization

/// Each regular expression a source-scanning guard uses, compiled once per
/// test process instead of once per call — or, inside a walk, once per
/// scanned file.
///
/// Most guards compile their patterns inside helpers that take the pattern
/// as a `String` (`matches(of:in:)`, `count(_:in:)`), called from many tests
/// and, in the walks, once per file of the tree. Measured on 2026-09-19 the
/// guards together held most of the cooperative pool's CPU on the Core test
/// process (`SourceCorpus` has the numbers); recompiling the same handful of
/// patterns thousands of times was part of that. A helper keeps its
/// signature and asks here instead, so no call site has to change and a
/// pattern stays written exactly once, where it is used.
///
/// Compilation happens outside the lock, so two threads meeting the same new
/// pattern may both compile it and one result is kept — both are the same
/// pattern, and nothing ever waits on a compilation but its own caller. A
/// pattern that does not compile throws exactly what `NSRegularExpression`
/// throws, every time, and is never cached.
public enum CompiledPattern {
    private static let cache = Mutex<[String: NSRegularExpression]>([:])

    /// `NSRegularExpression(pattern:)` with default options, once per
    /// distinct pattern.
    public static func regex(_ pattern: String) throws -> NSRegularExpression {
        if let hit = cache.withLock({ $0[pattern] }) { return hit }
        let compiled = try NSRegularExpression(pattern: pattern)
        cache.withLock { $0[pattern] = compiled }
        return compiled
    }
}
