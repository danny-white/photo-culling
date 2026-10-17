import Foundation

/// A parsed `Server-Timing` header such as
/// `total;dur=59.2, load;dur=49.7, cache;desc="miss", ext;desc=".arw"`.
///
/// Parsing never fails: malformed entries and parameters are skipped.
public struct ServerTiming: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public let name: String
        /// Duration in milliseconds.
        public let dur: Double?
        public let desc: String?

        public init(name: String, dur: Double? = nil, desc: String? = nil) {
            self.name = name
            self.dur = dur
            self.desc = desc
        }
    }

    /// In header order.
    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public init(header: String) {
        var entries: [Entry] = []
        for rawEntry in Self.split(header, on: ",") {
            var tokens = Self.split(rawEntry, on: ";").makeIterator()
            let name = (tokens.next() ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains("="), !name.contains("\"") else { continue }
            var dur: Double?
            var desc: String?
            while let token = tokens.next() {
                guard let equals = token.firstIndex(of: "=") else { continue }
                let key = token[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                let value = Self.unquote(String(token[token.index(after: equals)...]))
                switch key {
                case "dur" where dur == nil:
                    if let number = Double(value.trimmingCharacters(in: .whitespaces)), number.isFinite {
                        dur = number
                    }
                case "desc" where desc == nil:
                    desc = value
                default:
                    break
                }
            }
            entries.append(Entry(name: name, dur: dur, desc: desc))
        }
        self.entries = entries
    }

    /// Parses a header value; nil when the header is absent or holds no usable entry.
    public static func parse(_ header: String?) -> ServerTiming? {
        guard let header else { return nil }
        let timing = ServerTiming(header: header)
        return timing.entries.isEmpty ? nil : timing
    }

    /// The `dur` of the `total` entry.
    public var total: Double? { dur(of: "total") }

    /// The first entry with this name (case-insensitive).
    public func entry(named name: String) -> Entry? {
        entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func dur(of name: String) -> Double? { entry(named: name)?.dur }

    public func desc(of name: String) -> String? { entry(named: name)?.desc }

    // MARK: Parsing helpers

    /// Splits on a separator that is not inside a double-quoted string.
    private static func split(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in text {
            if inQuotes {
                current.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inQuotes = false
                }
            } else if character == "\"" {
                inQuotes = true
                current.append(character)
            } else if character == separator {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    /// Trims, then removes surrounding quotes and backslash escapes if the value is quoted.
    private static func unquote(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("\"") else { return text }
        var result = ""
        var escaped = false
        for character in text.dropFirst() {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                break
            } else {
                result.append(character)
            }
        }
        return result
    }
}
