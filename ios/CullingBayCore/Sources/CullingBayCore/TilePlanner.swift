import Foundation

// Small geometry types so the package needs no CoreGraphics.

public struct Point: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct Size: Sendable, Hashable, Codable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct Rect: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

/// One 1200 px cell of the full-resolution image, ready to request from the crop route.
public struct Tile: Sendable, Hashable, Identifiable {
    public let column: Int
    public let row: Int
    /// Position and size in source pixels, from the image's top-left.
    public let pixelRect: Rect
    /// The same rect as fractions of the image, for placing the tile over the picture.
    public let normalizedRect: Rect
    /// Crop request: the tile's centre as fractions of the upright frame.
    public let centerX: Double
    public let centerY: Double
    /// Crop request: size in source pixels. Edge tiles are smaller than 1200.
    public let width: Int
    public let height: Int

    public var id: String { "\(column),\(row)" }

    public init(
        column: Int, row: Int, pixelRect: Rect, normalizedRect: Rect,
        centerX: Double, centerY: Double, width: Int, height: Int
    ) {
        self.column = column
        self.row = row
        self.pixelRect = pixelRect
        self.normalizedRect = normalizedRect
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
    }
}

public struct TilePlan: Sendable, Hashable {
    public enum Level: Sendable, Hashable {
        /// The 1616 px picture is sharp enough.
        case view
        /// The 3000 px picture is sharp enough.
        case large
        /// Full-resolution crops, nearest the centre of the visible region first.
        case tiles([Tile])
    }

    public let level: Level
    /// Longest side, in device pixels, the image is drawn at:
    /// `max(fitSize.width, fitSize.height) * zoomScale * screenScale`. Compared with the pictures'
    /// longest sides, so portrait and landscape photos switch at the same sharpness.
    public let renderedPixelWidth: Double

    /// The tiles of a `.tiles` plan; empty for `.view` and `.large`.
    public var tiles: [Tile] {
        if case .tiles(let tiles) = level { return tiles }
        return []
    }

    public init(level: Level, renderedPixelWidth: Double) {
        self.level = level
        self.renderedPixelWidth = renderedPixelWidth
    }
}

/// Decides which picture to show for the viewer's zoom, and which full-resolution tiles to
/// fetch once zoomed in past the 3000 px picture. Pure maths.
public enum TilePlanner {
    /// Edge of a tile on the source image, in pixels.
    public static let tileSize = 1200
    /// The server's smallest crop. A strip narrower than this at the right or bottom edge joins
    /// the tile before it (making that one up to 1263 px), since the server would otherwise
    /// enlarge and shift the crop and the tile would land in the wrong place.
    public static let minCrop = 64
    public static let maxTiles = 16
    /// Longest side of the `view` and `large` pictures.
    public static let viewPixels = 1616.0
    public static let largePixels = 3000.0
    /// A picture is kept until the screen needs 15% more pixels than it has.
    public static let slack = 1.15

    /// - Parameters:
    ///   - sourceSize: full-resolution pixel size of the upright image (the `of WxH` in `X-Crop-Box`).
    ///   - fitSize: the image's on-screen size in points at zoom 1.
    ///   - zoomScale: current zoom, 1 or more.
    ///   - screenScale: device pixels per point.
    ///   - visible: the visible region in normalized image coordinates (0...1).
    public static func plan(
        sourceSize: Size, fitSize: Size, zoomScale: Double, screenScale: Double, visible: Rect
    ) -> TilePlan {
        let rendered = max(fitSize.width, fitSize.height) * zoomScale * screenScale
        if rendered <= viewPixels * slack {
            return TilePlan(level: .view, renderedPixelWidth: rendered)
        }
        if rendered <= largePixels * slack {
            return TilePlan(level: .large, renderedPixelWidth: rendered)
        }
        return TilePlan(
            level: .tiles(tiles(sourceSize: sourceSize, visible: visible)),
            renderedPixelWidth: rendered)
    }

    /// Burst frames shown side by side: the zoom for the `to` frame that shows the same number
    /// of source pixels per point as the `from` frame at `scale`. The centre is unchanged.
    /// `from` and `to` are the frames' fit sizes in points; their longest sides are compared, so
    /// a portrait frame next to a landscape one still lines up. The scale never goes below 1.
    public static func linkedZoom(
        center: Point, scale: Double, from: Size, to: Size
    ) -> (center: Point, scale: Double) {
        let fromSide = max(from.width, from.height)
        let toSide = max(to.width, to.height)
        guard fromSide > 0, toSide > 0 else { return (center, scale) }
        return (center, max(1, scale * fromSide / toSide))
    }

    // MARK: Tiles

    private static func tiles(sourceSize: Size, visible: Rect) -> [Tile] {
        guard sourceSize.width >= 1, sourceSize.height >= 1 else { return [] }
        let width = Int(sourceSize.width.rounded())
        let height = Int(sourceSize.height.rounded())
        let w = Double(width)
        let h = Double(height)
        let cell = Double(tileSize)
        let margin = cell / 4

        // Visible region in source pixels, clamped to the image, then grown by the margin.
        let left = max(0, clamp01(visible.x) * w - margin)
        let top = max(0, clamp01(visible.y) * h - margin)
        let right = min(w, clamp01(visible.x + visible.width) * w + margin)
        let bottom = min(h, clamp01(visible.y + visible.height) * h + margin)
        let centerX = (clamp01(visible.x) + clamp01(visible.x + visible.width)) / 2 * w
        let centerY = (clamp01(visible.y) + clamp01(visible.y + visible.height)) / 2 * h

        let columns = segments(width)
        let rows = segments(height)
        let pickedColumns = columns.indices.filter { overlaps(columns[$0], left, right) }
        let pickedRows = rows.indices.filter { overlaps(rows[$0], top, bottom) }

        var scored: [(distance: Double, tile: Tile)] = []
        for row in pickedRows {
            for column in pickedColumns {
                let (x0, tileW) = columns[column]
                let (y0, tileH) = rows[row]
                let tile = Tile(
                    column: column, row: row,
                    pixelRect: Rect(x: Double(x0), y: Double(y0), width: Double(tileW), height: Double(tileH)),
                    normalizedRect: Rect(
                        x: Double(x0) / w, y: Double(y0) / h,
                        width: Double(tileW) / w, height: Double(tileH) / h),
                    centerX: (Double(x0) + Double(tileW) / 2) / w,
                    centerY: (Double(y0) + Double(tileH) / 2) / h,
                    width: tileW, height: tileH)
                let dx = tile.pixelRect.midX - centerX
                let dy = tile.pixelRect.midY - centerY
                scored.append(((dx * dx + dy * dy).squareRoot(), tile))
            }
        }
        scored.sort { a, b in
            if a.distance != b.distance { return a.distance < b.distance }
            if a.tile.row != b.tile.row { return a.tile.row < b.tile.row }
            return a.tile.column < b.tile.column
        }
        return scored.prefix(maxTiles).map(\.tile)
    }

    /// (start, length) of each tile along one side: 1200 px cells from 0, the last one absorbing
    /// a remainder narrower than `minCrop`.
    static func segments(_ length: Int) -> [(start: Int, length: Int)] {
        guard length > 0 else { return [] }
        var out = stride(from: 0, to: length, by: tileSize).map { (start: $0, length: min(tileSize, length - $0)) }
        if out.count > 1, let last = out.last, last.length < minCrop {
            out.removeLast()
            out[out.count - 1].length += last.length
        }
        return out
    }

    private static func overlaps(_ segment: (start: Int, length: Int), _ low: Double, _ high: Double) -> Bool {
        Double(segment.start) < high && Double(segment.start + segment.length) > low
    }

    private static func clamp01(_ value: Double) -> Double {
        URLBuilding.clamp(value, 0...1)
    }
}
