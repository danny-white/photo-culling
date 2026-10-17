import Foundation

/// The `X-Crop-Box` header of a crop response: `left,top,w,h of WxH`. The box actually cut, in
/// source pixels, and the full-resolution size of the upright image, which `TilePlanner` needs
/// as `sourceSize`.
public struct CropBox: Sendable, Hashable {
    public let box: Rect
    public let sourceSize: Size

    public init(box: Rect, sourceSize: Size) {
        self.box = box
        self.sourceSize = sourceSize
    }

    /// Nil when the header is missing or not in that form.
    public init?(header: String?) {
        guard let header else { return nil }
        let halves = header.components(separatedBy: " of ")
        guard halves.count == 2 else { return nil }
        let box = halves[0].split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        let size = halves[1].lowercased().split(separator: "x").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard box.count == 4, size.count == 2, let l = box[0], let t = box[1], let w = box[2], let h = box[3],
              let sw = size[0], let sh = size[1], sw > 0, sh > 0 else { return nil }
        self.box = Rect(x: l, y: t, width: w, height: h)
        self.sourceSize = Size(width: sw, height: sh)
    }
}
