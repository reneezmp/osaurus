import Foundation

public struct KnowledgeFrontmatterField: Sendable, Equatable {
    public var key: String
    public var value: String
    public init(key: String, value: String) { self.key = key; self.value = value }
}

public struct KnowledgeFrontmatter: Sendable, Equatable {
    public var docType: String
    public var title: String
    public var summary: String
    public var tags: [String]
    public var extras: [KnowledgeFrontmatterField]
    public init(docType: String = "", title: String = "", summary: String = "", tags: [String] = [], extras: [KnowledgeFrontmatterField] = []) {
        self.docType = docType; self.title = title; self.summary = summary; self.tags = tags; self.extras = extras
    }
    public var tagsCSV: String { tags.joined(separator: ",") }
}

/// Dependency-free frontmatter parser and stable heading-aware chunker. It
/// intentionally accepts the useful YAML scalar/list subset without claiming
/// to be a general YAML parser.
public enum KnowledgeDocumentParser {
    static let targetChunkChars = 1_600
    static let maxChunkChars = 2_400

    public static func parse(markdown: String) -> (frontmatter: KnowledgeFrontmatter, body: String) {
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return (.init(), markdown) }
        guard let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" || $0.trimmingCharacters(in: .whitespacesAndNewlines) == "..." }) else { return (.init(), markdown) }
        let fieldLines = Array(lines[1..<close])
        var fields: [(String, String)] = []
        var index = 0
        while index < fieldLines.count {
            let line = fieldLines[index]
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { index += 1; continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                var list: [String] = []
                var cursor = index + 1
                while cursor < fieldLines.count {
                    let candidate = fieldLines[cursor].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix("- ") else { break }
                    list.append(clean(String(candidate.dropFirst(2))))
                    cursor += 1
                }
                if !list.isEmpty { value = list.joined(separator: ",") ; index = cursor - 1 }
            }
            fields.append((String(key), clean(String(value))))
            index += 1
        }
        var fm = KnowledgeFrontmatter()
        for (key, value) in fields {
            switch key.lowercased() {
            case "type": fm.docType = value
            case "title": fm.title = value
            case "description": fm.summary = value
            case "tags": fm.tags = normalizedTags(value)
            default: if !value.isEmpty { fm.extras.append(.init(key: key, value: value)) }
            }
        }
        return (fm, lines[close...].dropFirst().joined(separator: "\n"))
    }

    public static func resolveTitle(frontmatter: KnowledgeFrontmatter, body: String, relPath: String) -> String {
        if !frontmatter.title.isEmpty { return frontmatter.title }
        if let heading = body.components(separatedBy: .newlines).lazy.map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix("# ") && $0.count > 2 }) {
            return String(heading.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return ((relPath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    public static func chunk(body: String) -> [(headingPath: String, content: String)] {
        struct Section { var heading: String; var lines: [String] }
        var stack = Array(repeating: "", count: 6), sections = [Section(heading: "", lines: [])], fenced = false
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle() }
            if !fenced, let heading = heading(trimmed) {
                stack[heading.level - 1] = heading.text
                for index in heading.level..<stack.count { stack[index] = "" }
                sections.append(.init(heading: stack.prefix(heading.level).filter { !$0.isEmpty }.joined(separator: " > "), lines: []))
            } else { sections[sections.count - 1].lines.append(line) }
        }
        return sections.flatMap { section in split(section.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)).map { (section.heading, $0) } }
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let count = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count), line.dropFirst(count).first == " " else { return nil }
        let text = line.dropFirst(count).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (count, text)
    }

    private static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        if text.count <= maxChunkChars { return [text] }
        let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var result: [String] = [], current = ""
        for paragraph in paragraphs {
            if !current.isEmpty, current.count + paragraph.count + 2 > targetChunkChars { result.append(current); current = paragraph }
            else { current += current.isEmpty ? paragraph : "\n\n" + paragraph }
        }
        if !current.isEmpty { result.append(current) }
        return result.flatMap { part in
            guard part.count > maxChunkChars else { return [part] }
            var pieces: [String] = [], remaining = Substring(part)
            while !remaining.isEmpty { let piece = remaining.prefix(maxChunkChars); pieces.append(String(piece)); remaining = remaining.dropFirst(piece.count) }
            return pieces
        }
    }

    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
    private static func normalizedTags(_ value: String) -> [String] {
        let content = value.hasPrefix("[") && value.hasSuffix("]") ? String(value.dropFirst().dropLast()) : value
        var seen: Set<String> = []
        return content.components(separatedBy: ",").map(clean).map { $0.lowercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
