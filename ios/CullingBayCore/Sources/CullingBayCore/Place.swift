import Foundation

/// The town part of a place string: the text before the first comma, with the first letter of
/// each word uppercased. `"greenwood, washington, us"` gives `"Greenwood"`. Returns nil for a
/// nil, empty or blank town.
public func town(_ place: String?) -> String? {
    guard let place else { return nil }
    let head = place.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    let words = head.split(whereSeparator: \.isWhitespace).map { word in
        word.prefix(1).uppercased() + word.dropFirst()
    }
    return words.isEmpty ? nil : words.joined(separator: " ")
}
