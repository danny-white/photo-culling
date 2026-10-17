import Foundation

/// URL assembly shared by the client and the perf reporter.
enum URLBuilding {
    /// RFC 3986 unreserved characters. Everything else is percent-encoded, which is what Flask
    /// needs: it decodes `+` in a query as a space, so a literal `+` must go out as `%2B`.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// `path` is raw (not encoded). `/` separates segments and each segment is encoded, so
    /// `2026/2026-10-01` keeps its slash. Any path already on `base` is kept as a prefix.
    static func url(base: URL, path: String, query: [(name: String, value: String)] = []) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
            .map { encode(String($0)) }
        components.percentEncodedPath = basePath + "/" + segments.joined(separator: "/")
        components.percentEncodedQuery = query.isEmpty
            ? nil
            : query.map { "\(encode($0.name))=\(encode($0.value))" }.joined(separator: "&")
        components.fragment = nil
        return components.url ?? base
    }

    static func flag(_ value: Bool) -> String { value ? "1" : "0" }

    /// Fixed-point with at most 6 decimals and no trailing zeros: `0.5`, `1`, `0.123457`.
    static func fraction(_ value: Double) -> String {
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Clamp that also maps NaN to the lower bound instead of letting it through.
    static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        value.isNaN ? range.lowerBound : min(max(value, range.lowerBound), range.upperBound)
    }
}
