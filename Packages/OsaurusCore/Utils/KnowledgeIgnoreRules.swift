import Foundation

/// A deliberately small, predictable gitignore subset for collection scans.
public struct KnowledgeIgnoreRules: Sendable {
    private let rules: [(patterns: [String], negated: Bool)]
    private init(_ rules: [(patterns: [String], negated: Bool)]) { self.rules = rules }

    public func isIgnored(_ path: String) -> Bool {
        rules.reduce(false) { ignored, rule in
            rule.patterns.contains(where: { KnowledgeGlob.matchesPattern(path, pattern: $0) }) ? !rule.negated : ignored
        }
    }

    public static func forFolder(_ folder: URL) -> KnowledgeIgnoreRules {
        let text = (try? String(contentsOf: folder.appendingPathComponent(".gitignore"), encoding: .utf8)) ?? ""
        return parse(defaultPatterns + "\n" + text)
    }

    public static func parse(_ text: String) -> KnowledgeIgnoreRules {
        var rules: [(patterns: [String], negated: Bool)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let negated = line.hasPrefix("!")
            if negated { line.removeFirst() }
            let directoryOnly = line.hasSuffix("/")
            if directoryOnly { line.removeLast() }
            guard !line.isEmpty else { continue }
            let anchored = line.hasPrefix("/") || line.contains("/")
            if line.hasPrefix("/") { line.removeFirst() }
            let base = anchored ? line : "**/" + line
            var patterns = directoryOnly ? [] : [base]
            patterns.append(base + "/**")
            rules.append((patterns, negated))
        }
        return KnowledgeIgnoreRules(rules)
    }

    private static let defaultPatterns = """
    *.lock
    *.min.js
    *.min.css
    *.map
    *.png
    *.jpg
    *.jpeg
    *.gif
    *.zip
    .DS_Store
    """
}
