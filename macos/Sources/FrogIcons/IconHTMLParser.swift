import Foundation

enum IconURL {
    static func valid(_ value: String, relativeTo base: URL? = nil) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        components.fragment = nil
        return components.url
    }

    static func rootIcon(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        components.path = "/favicon.ico"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

struct IconCandidate: Equatable, Sendable {
    let url: URL
    let declaredSize: Int
    let isTouchIcon: Bool
}

enum IconHTMLParser {
    static func candidates(in html: String, finalPageURL: URL) -> [IconCandidate] {
        // 排除注释和原始文本元素，避免把脚本里的字符串当成真实声明。
        let excluded = #"(?is)<!--.*?(?:-->|$)|<(script|style|textarea|title)\b[^>]*>.*?(?:</\1\s*>|$)"#
        let cleaned = html.replacingOccurrences(of: excluded, with: "", options: .regularExpression)
        let tagPattern = #"(?is)<(link|base)\b((?:\"[^\"]*\"|'[^']*'|[^'\">])*)>"#
        guard let regex = try? NSRegularExpression(pattern: tagPattern) else { return [] }
        let source = cleaned as NSString
        let tags = regex.matches(in: cleaned, range: NSRange(location: 0, length: source.length))
        var base = finalPageURL
        var foundBase = false
        var declarations: [[String: String]] = []
        for tag in tags {
            let name = source.substring(with: tag.range(at: 1)).lowercased()
            let attributes = parseAttributes(source.substring(with: tag.range(at: 2)))
            if name == "base", !foundBase, let href = attributes["href"],
               let url = IconURL.valid(href, relativeTo: finalPageURL) {
                base = url
                foundBase = true
            } else if name == "link" {
                declarations.append(attributes)
            }
        }
        var seen = Set<URL>()
        return declarations.compactMap { attributes -> IconCandidate? in
            let relations = Set((attributes["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            let touch = relations.contains("apple-touch-icon") || relations.contains("apple-touch-icon-precomposed")
            guard relations.contains("icon") || touch, let href = attributes["href"],
                  let url = IconURL.valid(href, relativeTo: base), seen.insert(url).inserted else { return nil }
            let declaredSize = (attributes["sizes"] ?? "").lowercased().split(whereSeparator: \.isWhitespace).compactMap { size -> Int? in
                let parts = size.split(separator: "x")
                guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else { return nil }
                return min(width, height)
            }.max() ?? (touch ? 180 : 0)
            return IconCandidate(url: url, declaredSize: declaredSize, isTouchIcon: touch)
        }.enumerated().sorted { lhs, rhs in
            if lhs.element.declaredSize != rhs.element.declaredSize { return lhs.element.declaredSize > rhs.element.declaredSize }
            if lhs.element.isTouchIcon != rhs.element.isTouchIcon { return lhs.element.isTouchIcon }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func parseAttributes(_ text: String) -> [String: String] {
        let pattern = #"([^\s=/'\"<>`]+)\s*(?:=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'`=<>]+)))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let source = text as NSString
        var attributes: [String: String] = [:]
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let name = source.substring(with: match.range(at: 1)).lowercased()
            guard attributes[name] == nil else { continue }
            let valueRange = (2...4).map { match.range(at: $0) }.first { $0.location != NSNotFound }
            attributes[name] = decodeEntities(valueRange.map(source.substring(with:)) ?? "")
        }
        return attributes
    }

    private static func decodeEntities(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&(#x[0-9a-f]+|#[0-9]+|amp|quot|apos|lt|gt);"#, options: .caseInsensitive) else { return text }
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).reversed() {
            let entity = (text as NSString).substring(with: match.range(at: 1)).lowercased()
            let names = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">"]
            let replacement: String?
            if entity.hasPrefix("#x") {
                replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init).map(String.init)
            } else if entity.hasPrefix("#") {
                replacement = UInt32(entity.dropFirst()).flatMap(UnicodeScalar.init).map(String.init)
            } else {
                replacement = names[entity]
            }
            if let replacement { result.replaceCharacters(in: match.range, with: replacement) }
        }
        return result as String
    }
}
