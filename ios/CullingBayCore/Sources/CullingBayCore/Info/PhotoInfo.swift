import Foundation

/// One photo's camera details (`GET /m/api/info/<id>`), read from the file itself by the PC. The
/// index keeps none of them, so every field but `id` and `file` can be missing, and the phone
/// never saves them: they are asked for when the (i) sheet opens (`CullingBayClient.info`).
///
/// Decoding is forgiving. A key the server adds later is ignored, and `gps` that is not a
/// `[lat, lon]` pair of numbers is nil rather than an error: a sheet with no map link is better
/// than no sheet. Values are as the file holds them (`shutter_s` in seconds, `aperture` an
/// f-number); `PhotoInfoFormat` turns them into words.
public struct PhotoInfo: Decodable, Sendable, Hashable, Identifiable {
    public let id: Int
    /// File name, e.g. `DSC04912.ARW`.
    public let file: String
    /// The file type in exiftool's words, e.g. `ARW`, `DNG`, `JPEG`, `HEIC`.
    public let format: String?
    /// Size of the file.
    public let bytes: Int?
    public let width: Int?
    public let height: Int?
    public let megapixels: Double?
    /// Make and model in one name, e.g. `Sony ILCE-7RM3`.
    public let camera: String?
    public let make: String?
    public let model: String?
    public let lens: String?
    public let iso: Int?
    /// Exposure time in seconds (0.0004 is 1/2500 s).
    public let shutterSeconds: Double?
    /// The f-number: 4 is f/4.
    public let aperture: Double?
    public let focalMM: Double?
    /// The focal length a full-frame camera would need for the same view.
    public let focal35MM: Double?
    /// Exposure compensation in stops.
    public let ev: Double?
    /// The exposure mode, in exiftool's words: `Aperture-priority AE`, `Manual`.
    public let program: String?
    public let metering: String?
    public let flash: String?
    public let whiteBalance: String?
    public let focusMode: String?
    /// When it was taken: `YYYY:MM:DD HH:MM:SS`, with `.fraction` on some cameras. The camera's
    /// own clock, with no zone.
    public let taken: String?
    /// The zone of `taken`, such as `-07:00`.
    public let offset: String?
    public let gps: Coordinates?
    /// The nearest town, as in `Photo.place`.
    public let place: String?

    /// Where the photo was taken, in degrees.
    public struct Coordinates: Sendable, Hashable {
        public let latitude: Double
        public let longitude: Double

        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    public init(
        id: Int, file: String, format: String? = nil, bytes: Int? = nil, width: Int? = nil,
        height: Int? = nil, megapixels: Double? = nil, camera: String? = nil, make: String? = nil,
        model: String? = nil, lens: String? = nil, iso: Int? = nil, shutterSeconds: Double? = nil,
        aperture: Double? = nil, focalMM: Double? = nil, focal35MM: Double? = nil, ev: Double? = nil,
        program: String? = nil, metering: String? = nil, flash: String? = nil,
        whiteBalance: String? = nil, focusMode: String? = nil, taken: String? = nil,
        offset: String? = nil, gps: Coordinates? = nil, place: String? = nil
    ) {
        self.id = id
        self.file = file
        self.format = format
        self.bytes = bytes
        self.width = width
        self.height = height
        self.megapixels = megapixels
        self.camera = camera
        self.make = make
        self.model = model
        self.lens = lens
        self.iso = iso
        self.shutterSeconds = shutterSeconds
        self.aperture = aperture
        self.focalMM = focalMM
        self.focal35MM = focal35MM
        self.ev = ev
        self.program = program
        self.metering = metering
        self.flash = flash
        self.whiteBalance = whiteBalance
        self.focusMode = focusMode
        self.taken = taken
        self.offset = offset
        self.gps = gps
        self.place = place
    }

    enum CodingKeys: String, CodingKey {
        case id, file, format, bytes, width, height, megapixels, camera, make, model, lens, iso
        case shutterSeconds = "shutter_s"
        case aperture
        case focalMM = "focal_mm"
        case focal35MM = "focal_35mm"
        case ev, program, metering, flash
        case whiteBalance = "white_balance"
        case focusMode = "focus_mode"
        case taken, offset, gps, place
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        file = try c.decode(String.self, forKey: .file)
        format = try c.decodeIfPresent(String.self, forKey: .format)
        bytes = try Self.wholeNumber(c, .bytes)
        width = try Self.wholeNumber(c, .width)
        height = try Self.wholeNumber(c, .height)
        megapixels = try c.decodeIfPresent(Double.self, forKey: .megapixels)
        camera = try c.decodeIfPresent(String.self, forKey: .camera)
        make = try c.decodeIfPresent(String.self, forKey: .make)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        lens = try c.decodeIfPresent(String.self, forKey: .lens)
        iso = try Self.wholeNumber(c, .iso)
        shutterSeconds = try c.decodeIfPresent(Double.self, forKey: .shutterSeconds)
        aperture = try c.decodeIfPresent(Double.self, forKey: .aperture)
        focalMM = try c.decodeIfPresent(Double.self, forKey: .focalMM)
        focal35MM = try c.decodeIfPresent(Double.self, forKey: .focal35MM)
        ev = try c.decodeIfPresent(Double.self, forKey: .ev)
        program = try c.decodeIfPresent(String.self, forKey: .program)
        metering = try c.decodeIfPresent(String.self, forKey: .metering)
        flash = try c.decodeIfPresent(String.self, forKey: .flash)
        whiteBalance = try c.decodeIfPresent(String.self, forKey: .whiteBalance)
        focusMode = try c.decodeIfPresent(String.self, forKey: .focusMode)
        taken = try c.decodeIfPresent(String.self, forKey: .taken)
        offset = try c.decodeIfPresent(String.self, forKey: .offset)
        // Anything but two numbers is no position, not a failure.
        let pair = (try? c.decodeIfPresent([Double].self, forKey: .gps)) ?? nil
        gps = pair.flatMap { $0.count == 2 ? Coordinates(latitude: $0[0], longitude: $0[1]) : nil }
        place = try c.decodeIfPresent(String.self, forKey: .place)
    }

    /// A count the file may write as `100` or `100.0`.
    private static func wholeNumber(
        _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) throws -> Int? {
        guard let value = try c.decodeIfPresent(Double.self, forKey: key) else { return nil }
        return Int(exactly: value.rounded())
    }
}

/// The details already fetched, so opening the sheet again on the same photo is instant. In memory
/// only and held by the client, so it ends with the app and with a change of server; a failed
/// request is never put in. The oldest entry goes first once `limit` is passed.
struct PhotoInfoCache: Sendable {
    /// How many photos' details are kept.
    static let limit = 64

    private var entries: [Int: PhotoInfo] = [:]
    private var order: [Int] = []          // least recently used first

    var count: Int { entries.count }

    mutating func value(for id: Int) -> PhotoInfo? {
        guard let info = entries[id] else { return nil }
        order.removeAll { $0 == id }
        order.append(id)
        return info
    }

    mutating func remember(_ info: PhotoInfo, for id: Int) {
        entries[id] = info
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > Self.limit {
            entries[order.removeFirst()] = nil
        }
    }
}
