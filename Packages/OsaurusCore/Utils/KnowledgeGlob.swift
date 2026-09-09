import Foundation

public enum KnowledgeGlob {
    public static func matches(_ relPath: String, include: [String], exclude: [String]) -> Bool {
        if exclude.contains(where: { matchesPattern(relPath, pattern: $0) }) { return false }
        return include.isEmpty || include.contains(where: { matchesPattern(relPath, pattern: $0) })
    }

    public static func matchesPattern(_ relPath: String, pattern: String) -> Bool {
        let path = normalize(relPath), pattern = normalize(pattern)
        guard !pattern.isEmpty, let regex = try? NSRegularExpression(pattern: regexString(for: pattern)) else { return false }
        return regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    static func regexString(for pattern: String) -> String {
        var result = "^", i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            if c == "*" {
                let next = pattern.index(after: i)
                if next < pattern.endIndex, pattern[next] == "*" {
                    let after = pattern.index(after: next)
                    if after < pattern.endIndex, pattern[after] == "/" { result += "(?:.*/)?"; i = pattern.index(after: after) }
                    else { result += ".*"; i = after }
                } else { result += "[^/]*"; i = next }
            } else if c == "?" { result += "[^/]"; i = pattern.index(after: i) }
            else { result += NSRegularExpression.escapedPattern(for: String(c)); i = pattern.index(after: i) }
        }
        return result + "$"
    }

    private static func normalize(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("./") { value.removeFirst(2) }
        while value.hasPrefix("/") { value.removeFirst() }
        return value
    }
}
