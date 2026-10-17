import Foundation
import Testing
@testable import CullingBayCore

@Suite("Models")
struct ModelsTests {
    let decoder = JSONDecoder()

    @Test func dayDecodesEveryField() throws {
        let day = try decoder.decode(Day.self, from: Data(dayFullJSON.utf8))
        #expect(day.id == "2026/2026-10-01")
        #expect(day.folder == "2026-10-01")
        #expect(day.date == "2026-10-01")
        #expect(day.frames == 120)
        #expect(day.stacks == 84)
        #expect(day.thumbs == [43220, 43197, 43203])
        #expect(day.lastTs == 1790879999.75)
        #expect(day.place == "greenwood, washington, us")
        #expect(day.places == ["greenwood", "seattle"])
        #expect(day.gpsFrames == 97)
        #expect(day.summary == "Dune walk and sunset")
        #expect(day.decided == 80)
        #expect(day.sent == 60)
        #expect(day.landed == 55)
        #expect(day.conflicts == 2)
        #expect(day.lrDone == 50)
        #expect(day.finished)
        #expect(day.sentAt == "2026-10-02T08:30:00")
    }

    @Test func dayDecodesNullsInEveryOptionalField() throws {
        let day = try decoder.decode(Day.self, from: Data(dayNullsJSON.utf8))
        #expect(day.date == nil)
        #expect(day.place == nil)
        #expect(day.summary == nil)
        #expect(day.sentAt == nil)
        #expect(day.isoDate == nil)
        #expect(day.thumbs.isEmpty)
        #expect(day.lastTs == 1_700_000_000)
        #expect(!day.finished)
    }

    @Test func dayDecodesWhenOptionalKeysAreMissing() throws {
        let json = """
        {"day":"d","folder":"d","frames":1,"stacks":1,"thumbs":[],"last_ts":1,"places":[],
         "gps_frames":0,"decided":0,"sent":0,"landed":0,"conflicts":0,"lr_done":0,"finished":false}
        """
        let day = try decoder.decode(Day.self, from: Data(json.utf8))
        #expect(day.date == nil && day.place == nil && day.summary == nil && day.sentAt == nil)
    }

    @Test func lastTsAcceptsAnIntegerLiteralToo() throws {
        let json = dayNullsJSON.replacingOccurrences(of: "1700000000.0", with: "1700000000")
        let day = try decoder.decode(Day.self, from: Data(json.utf8))
        #expect(day.lastTs == 1_700_000_000)
    }

    @Test func photoDecodesEveryField() throws {
        let photo = try decoder.decode(Photo.self, from: Data(photoFullJSON.utf8))
        #expect(photo.id == 43203)
        #expect(photo.day == "2026/2026-10-01")
        #expect(photo.date == "2026-10-01")
        #expect(photo.ts == 1790871550)
        #expect(photo.file == "DSC05040.ARW")
        #expect(photo.bytes == 43_100_672)
        #expect(photo.camera == "SONY ILCE-7RM3")
        #expect(photo.lens == "24-70mm F2.8 DG DN | Art 019")
        #expect(photo.caption == "silhouettes on a cliff")
        #expect(photo.place == "greenwood, washington, us")
        #expect(photo.stars == 3)
        #expect(photo.picked)
        #expect(!photo.rejected)
        #expect(photo.raw)
    }

    @Test func photoDecodesNullsInEveryOptionalField() throws {
        let photo = try decoder.decode(Photo.self, from: Data(photoNullsJSON.utf8))
        #expect(photo.date == nil)
        #expect(photo.ts == nil)
        #expect(photo.bytes == nil)
        #expect(photo.camera == nil)
        #expect(photo.lens == nil)
        #expect(photo.caption == nil)
        #expect(photo.place == nil)
        #expect(photo.captureDate == nil)
        #expect(photo.isoDate == nil)
        #expect(!photo.raw)
    }

    @Test func photoListDecodesASearchWithQuery() throws {
        let json = """
        {"query":"DSC05040","total":4,"signals":["words"],"notes":["captions are off"],
         "photos":[\(photoFullJSON),\(photoNullsJSON)]}
        """
        let list = try decoder.decode(PhotoList.self, from: Data(json.utf8))
        #expect(list.query == "DSC05040")
        #expect(list.total == 4)
        #expect(list.signals == ["words"])
        #expect(list.notes == ["captions are off"])
        #expect(list.photos.map(\.id) == [43203, 7])
    }

    @Test func photoListDecodesALikeWithoutQuery() throws {
        let json = #"{"total":0,"signals":[],"notes":[],"photos":[]}"#
        let list = try decoder.decode(PhotoList.self, from: Data(json.utf8))
        #expect(list.query == nil)
        #expect(list.photos.isEmpty)
    }

    @Test func galleryDayDecodesWithAndWithoutDateAndSummary() throws {
        let full = try decoder.decode(GalleryDay.self, from: Data(galleryDayJSON().utf8))
        #expect(full.day == "2026/2026-10-01")
        #expect(full.date == "2026-10-01")
        #expect(full.summary == "A day")
        #expect(full.photos.count == 1)

        let nulls = #"{"day":"x/y","date":null,"summary":null,"photos":[]}"#
        let empty = try decoder.decode(GalleryDay.self, from: Data(nulls.utf8))
        #expect(empty.date == nil && empty.summary == nil && empty.photos.isEmpty)
    }

    @Test func encodingUsesSnakeCaseKeysAndRoundTrips() throws {
        let day = try decoder.decode(Day.self, from: Data(dayFullJSON.utf8))
        let data = try JSONEncoder().encode(day)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["last_ts", "gps_frames", "lr_done", "sent_at"] {
            #expect(object[key] != nil, "missing \(key)")
        }
        #expect(object["lastTs"] == nil)
        #expect(try decoder.decode(Day.self, from: data) == day)

        let photo = try decoder.decode(Photo.self, from: Data(photoFullJSON.utf8))
        #expect(try decoder.decode(Photo.self, from: JSONEncoder().encode(photo)) == photo)
    }

    @Test func modelsAreHashableAndIdentifiable() throws {
        let a = try decoder.decode(Photo.self, from: Data(photoFullJSON.utf8))
        let b = try decoder.decode(Photo.self, from: Data(photoFullJSON.utf8))
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
        #expect(a.id == 43203)
    }

    // MARK: Helpers

    @Test func captureDateIsEpochSeconds() throws {
        let photo = makePhoto(ts: 1_790_871_364.5)
        #expect(photo.captureDate == Date(timeIntervalSince1970: 1_790_871_364.5))
        // 2026-10-01 16:16:04 as the camera's wall clock read in UTC.
        let parts = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(identifier: "UTC")!, from: try #require(photo.captureDate))
        #expect(parts.year == 2026 && parts.month == 10 && parts.day == 1)
        #expect(parts.hour == 16 && parts.minute == 16)
    }

    @Test func isoDateParsesAndRejects() {
        let ok = parseISODate("2026-10-01")
        #expect(ok?.year == 2026 && ok?.month == 10 && ok?.day == 1)
        #expect(parseISODate("2024-02-29")?.day == 29)
        #expect(parseISODate("2026-02-29") == nil)
        for bad in ["", "2026-10", "2026-13-01", "2026-00-10", "2026-10-32", "abc", "2026/10/01",
                    "26-10-01", "2026-1-1", "2026-10-+1", "2026-10-01T00:00"] {
            #expect(parseISODate(bad) == nil, "\(bad)")
        }
        #expect(parseISODate(nil) == nil)
    }

    @Test func dayAndPhotoExposeIsoDate() throws {
        let day = try decoder.decode(Day.self, from: Data(dayFullJSON.utf8))
        #expect(day.isoDate?.year == 2026 && day.isoDate?.month == 10 && day.isoDate?.day == 1)
        let photo = try decoder.decode(Photo.self, from: Data(photoFullJSON.utf8))
        #expect(photo.isoDate?.day == 1)
    }

    @Test func townIsTheFirstCommaPartCapitalised() {
        #expect(town("greenwood, washington, us") == "Greenwood")
        #expect(town("port townsend, washington, us") == "Port Townsend")
        #expect(town("West Bishop, California, United States") == "West Bishop")
        #expect(town("seattle") == "Seattle")
        #expect(town("  new   york , ny") == "New York")
        #expect(town("élan, france") == "Élan")
    }

    @Test func townIsNilForNilEmptyOrBlank() {
        #expect(town(nil) == nil)
        #expect(town("") == nil)
        #expect(town("   ") == nil)
        #expect(town(", washington, us") == nil)
    }

    // MARK: Saving

    @Test func saveKindsOfARawAreBoth() {
        #expect(makePhoto(raw: true).saveKinds == [.picture, .raw])
    }

    @Test func saveKindsOfANonRawIsThePictureOnly() {
        #expect(makePhoto(file: "IMG_1.JPG", raw: false).saveKinds == [.picture])
    }

    @Test func saveFilenames() {
        let raw = makePhoto(file: "DSC05040.ARW", raw: true)
        #expect(raw.saveFilename(.picture) == "DSC05040.jpg")
        #expect(raw.saveFilename(.raw) == "DSC05040.ARW")

        let jpeg = makePhoto(file: "IMG_0001.JPG", raw: false)
        #expect(jpeg.saveFilename(.picture) == "IMG_0001.JPG")
        #expect(jpeg.saveFilename(.raw) == "IMG_0001.JPG")

        let dotted = makePhoto(file: "trip.day1.CR3", raw: true)
        #expect(dotted.saveFilename(.picture) == "trip.day1.jpg")

        let bare = makePhoto(file: "NOEXT", raw: true)
        #expect(bare.saveFilename(.picture) == "NOEXT.jpg")
    }
}
