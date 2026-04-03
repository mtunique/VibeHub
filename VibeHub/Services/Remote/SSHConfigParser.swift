import Foundation

struct SSHConfigEntry: Identifiable, Equatable, Sendable {
    var id: String { alias }
    let alias: String
    let hostName: String?
    let user: String?
    let port: Int?
    let identityFile: String?
    /// Whether GSSAPI authentication is enabled (GSSAPIAuthentication=yes)
    let useGSSAPI: Bool
}

enum SSHConfigParser {
    static func loadUserConfig() -> [SSHConfigEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent(".ssh/config")
        return loadConfig(at: path)
    }

    private static func loadConfig(at url: URL) -> [SSHConfigEntry] {
        let raw = readConfigWithIncludes(url: url, visited: Set([url.path]), depth: 0)
        guard let raw else { return [] }
        return parse(raw)
    }

    private static func readConfigWithIncludes(url: URL, visited: Set<String>, depth: Int) -> String? {
        guard depth <= 8 else { return nil }
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }

        var outLines: [String] = []
        let baseDir = url.deletingLastPathComponent()

        for line in raw.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("include ") {
                let rest = trimmed.dropFirst("include".count).trimmingCharacters(in: .whitespacesAndNewlines)
                let patterns = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                for pattern in patterns {
                    for inc in resolveInclude(pattern: pattern, baseDir: baseDir) {
                        if visited.contains(inc.path) { continue }
                        var nextVisited = visited
                        nextVisited.insert(inc.path)
                        if let more = readConfigWithIncludes(url: inc, visited: nextVisited, depth: depth + 1) {
                            outLines.append(more)
                        }
                    }
                }
            } else {
                outLines.append(line)
            }
        }

        return outLines.joined(separator: "\n")
    }

    private static func resolveInclude(pattern: String, baseDir: URL) -> [URL] {
        let expanded = expandTilde(pattern) ?? pattern

        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded)
        } else {
            url = baseDir.appendingPathComponent(expanded)
        }

        // Glob support: * and ?
        if url.path.contains("*") || url.path.contains("?") {
            let dir = url.deletingLastPathComponent()
            let pat = url.lastPathComponent
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
                return []
            }
            let regex = globToRegex(pat)
            return names
                .filter { regex.matches($0) }
                .map { dir.appendingPathComponent($0) }
        }

        return [url]
    }

    private static func globToRegex(_ pattern: String) -> NSRegularExpression {
        var s = "^"
        for ch in pattern {
            switch ch {
            case "*":
                s += ".*"
            case "?":
                s += "."
            case ".", "(", ")", "[", "]", "{", "}", "^", "$", "+", "|", "\\":
                s += "\\\\\(ch)"
            default:
                s += String(ch)
            }
        }
        s += "$"
        return (try? NSRegularExpression(pattern: s)) ?? NSRegularExpression()
    }

    static func parse(_ raw: String) -> [SSHConfigEntry] {
        var results: [SSHConfigEntry] = []

        struct Block {
            var hosts: [String] = []
            var hostName: String?
            var user: String?
            var port: Int?
            var identityFile: String?
            var useGSSAPI: Bool = false
        }

        func flush(_ block: Block) {
            guard !block.hosts.isEmpty else { return }
            for h in block.hosts {
                // Skip patterns/wildcards and negations
                if h.contains("*") || h.contains("?") || h.contains("!") { continue }
                let entry = SSHConfigEntry(
                    alias: h,
                    hostName: block.hostName,
                    user: block.user,
                    port: block.port,
                    identityFile: expandTilde(block.identityFile),
                    useGSSAPI: block.useGSSAPI
                )
                results.append(entry)
            }
        }

        var current = Block()
        let lines = raw.split(whereSeparator: \.isNewline).map(String.init)
        for line in lines {
            // Remove inline comments (but not # within quoted strings)
            let decommented = removeInlineComments(line)
            let trimmed = decommented.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            // Very small tokenizer: "Key value..." (ssh config is space-separated)
            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 1 else { continue }
            let key = parts[0].lowercased()
            let value = (parts.count == 2)
                ? parts[1].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                : ""

            if key == "host" {
                flush(current)
                current = Block()
                let tokens = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
                current.hosts = tokens.map(String.init)
                continue
            }

            switch key {
            case "hostname":
                current.hostName = value
            case "user":
                current.user = value
            case "port":
                current.port = Int(value)
            case "identityfile":
                current.identityFile = value
            case "gssapiauthentication":
                current.useGSSAPI = value.lowercased() == "yes"
            case "gssapidelegatecredentials":
                if value.lowercased() == "yes" {
                    current.useGSSAPI = true
                }
            default:
                break
            }
        }

        flush(current)

        // De-dupe by alias (keep the first occurrence)
        var seen = Set<String>()
        return results.filter { e in
            if seen.contains(e.alias) { return false }
            seen.insert(e.alias)
            return true
        }
        .sorted { $0.alias.lowercased() < $1.alias.lowercased() }
    }

    private static func removeInlineComments(_ line: String) -> String {
        var result = ""
        var inQuote = false
        var quoteChar: Character = "\""
        for ch in line {
            if !inQuote && (ch == "\"" || ch == "'") {
                inQuote = true
                quoteChar = ch
                result.append(ch)
            } else if inQuote && ch == quoteChar {
                inQuote = false
                result.append(ch)
            } else if !inQuote && ch == "#" {
                return result
            } else {
                result.append(ch)
            }
        }
        return result
    }

    private static func expandTilde(_ path: String?) -> String? {
        guard let path else { return nil }
        guard path.hasPrefix("~") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst()) }
        return path
    }
}

private extension NSRegularExpression {
    func matches(_ s: String) -> Bool {
        let range = NSRange(location: 0, length: (s as NSString).length)
        return firstMatch(in: s, options: [], range: range) != nil
    }
}
