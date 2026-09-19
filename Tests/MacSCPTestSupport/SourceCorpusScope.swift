import Foundation

/// The check behind both targets' `SourceCorpusScopeTests`: what
/// `SourceCorpus` lists equals what a direct walk of the same directory
/// finds, directory by directory, so a guard reading through the corpus
/// cannot silently scan less than the tree holds.
///
/// The direct walk is deliberately a different API from the corpus's own:
/// `subpathsOfDirectory(atPath:)` plus `fileExists(atPath:isDirectory:)` for
/// the sets, and a fresh `FileManager` enumerator per directory for the
/// order. A shared helper would compare the corpus with itself.
///
/// Lives in the support module so the Core and AppKit test processes —
/// separate processes locally, each with its own corpus — both run it
/// against the instance they actually use.
public enum SourceCorpusScope {
    /// One root's measurement: how much the direct walk found, and every
    /// disagreement with the corpus (empty when they agree).
    public struct Report: Sendable {
        public let root: SourceCorpus.Root
        public let directWalkFiles: Int
        public let directWalkDirectories: Int
        public let swiftFiles: Int
        public let mismatches: [String]
    }

    public static func check(_ root: SourceCorpus.Root) throws -> Report {
        let manager = FileManager.default
        let rootURL = SourceCorpus.url(of: root)
        let rootPath = SourceCorpus.key(rootURL)
        var files: [String] = []
        var directories: [String] = []
        for relative in try manager.subpathsOfDirectory(atPath: rootPath) {
            let path = rootPath + "/" + relative
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue { directories.append(path) } else { files.append(path) }
        }
        var mismatches: [String] = []
        func compare(_ label: String, corpus: [String], direct: [String]) {
            let missing = Set(direct).subtracting(corpus)
            let extra = Set(corpus).subtracting(direct)
            if !missing.isEmpty { mismatches.append("\(label): the corpus lacks \(missing.sorted())") }
            if !extra.isEmpty { mismatches.append("\(label): the corpus adds \(extra.sorted())") }
            if corpus.count != Set(corpus).count { mismatches.append("\(label): the corpus lists a file twice") }
        }

        compare(
            "directories of \(root.rawValue)", corpus: try SourceCorpus.directories(in: root),
            direct: directories)

        for directory in [rootPath] + directories {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            let under = try SourceCorpus.files(under: url).map(SourceCorpus.key)
            compare(
                "files under \(directory)", corpus: under,
                direct: files.filter { $0.hasPrefix(directory + "/") })
            compare(
                "children of \(directory)", corpus: try SourceCorpus.children(of: url).map(SourceCorpus.key),
                direct: try manager.contentsOfDirectory(atPath: directory).map { directory + "/" + $0 }
                    .filter { path in
                        var isDirectory: ObjCBool = false
                        return manager.fileExists(atPath: path, isDirectory: &isDirectory)
                            && !isDirectory.boolValue
                    })
            // Order, against the enumerator a guard used to call itself.
            if let walker = manager.enumerator(at: url, includingPropertiesForKeys: nil) {
                let enumerated = walker.compactMap { $0 as? URL }.map(SourceCorpus.key)
                    .filter { path in
                        var isDirectory: ObjCBool = false
                        return manager.fileExists(atPath: path, isDirectory: &isDirectory)
                            && !isDirectory.boolValue
                    }
                if enumerated != under {
                    mismatches.append("files under \(directory): not in the enumerator's order")
                }
            } else {
                mismatches.append("\(directory): the enumerator refused it")
            }
        }

        // Every file's text is the file's text. The blanked views are not
        // walked here: building one costs a full blanking pass over its
        // root, and this check must not force a view no guard in the
        // process reads. `SourceCorpusScopeTests` compares one file's views
        // with the stripper's own output instead.
        var swiftFiles = 0
        for path in files {
            let url = URL(fileURLWithPath: path)
            guard let disk = try? String(contentsOf: url, encoding: .utf8) else {
                if SourceCorpus.contains(url), (try? SourceCorpus.text(of: url)) != nil {
                    mismatches.append("\(path): the corpus has text for a file that is not UTF-8")
                }
                continue
            }
            guard (try? SourceCorpus.text(of: url)) == disk else {
                mismatches.append("\(path): the corpus text differs from the file")
                continue
            }
            if url.pathExtension == "swift" { swiftFiles += 1 }
        }
        return Report(
            root: root, directWalkFiles: files.count, directWalkDirectories: directories.count,
            swiftFiles: swiftFiles, mismatches: mismatches)
    }
}
