import Foundation

extension Duration {
    /// For the `ms` of a perf mark.
    var inMilliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
