import Foundation
import Testing
@testable import CullingBayCore

@Suite("Offline: store")
struct OfflineStoreTests {
    let day = "2026/2026-09-29"

    @Test func aDayIdBecomesAFileNameThatNeverCollides() {
        #expect(OfflineStore.key(for: "2026/2026-09-29") == "2026_2026-09-29")
        #expect(OfflineStore.key(for: "misc/unsorted") == "misc_unsorted")
        #expect(OfflineStore.key(for: "a b/ü") == "a%20b_%C3%BC")
        #expect(OfflineStore.key(for: "a_b") != OfflineStore.key(for: "a/b"))
        #expect(OfflineStore.key(for: "../x") == ".._x")      // no slash survives, so no path out
    }

    @Test func blobsRoundTripUnderTheLayoutTheBriefNames() throws {
        let root = TempRoot()
        let store = root.store()
        #expect(store.readDays() == nil)
        try store.writeDays(Data("days".utf8))
        try store.writeDay(day, Data("day".utf8))
        try store.writeImage(Data("t".utf8), kind: .thumb, id: 7)
        try store.writeImage(Data("v".utf8), kind: .view, id: 7)
        try store.writeImage(Data("a".utf8), kind: .af, id: 7)
        #expect(store.readDays() == Data("days".utf8))
        #expect(store.readDay(day) == Data("day".utf8))
        #expect(store.readImage(.thumb, id: 7) == Data("t".utf8))
        #expect(store.hasImage(.view, id: 7))
        #expect(!store.hasImage(.view, id: 8))
        let files = ["days.json", "day/2026_2026-09-29.json", "img/7-thumb.jpg", "img/7-view.jpg", "af/7.jpg"]
        for file in files {
            #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent(file).path), "\(file)")
        }
    }

    @Test func aDayIsSavedOnlyOnceItIsFinished() throws {
        let root = TempRoot()
        let store = root.store()
        try store.begin(day: day, frames: 3, photos: [1, 2])
        try store.writeDay(day, Data("day".utf8))
        try store.writeImage(Data(count: 100), kind: .thumb, id: 1)
        #expect(!store.isSaved(day))
        #expect(store.savedDays.isEmpty)
        #expect(store.bytes(of: day) == 0)
        #expect(store.record(for: day)?.complete == false)

        let record = try #require(try store.finish(day: day))
        #expect(record.complete)
        #expect(record.frames == 3)
        #expect(record.photos == [1, 2])
        #expect(record.bytes == 103)                        // the day's JSON and the one picture
        #expect(store.isSaved(day))
        #expect(store.savedDays == [day])
        #expect(store.bytes(of: day) == 103)
        #expect(try store.finish(day: "never/begun") == nil)
    }

    @Test func theManifestSurvivesARelaunch() throws {
        let root = TempRoot()
        let first = root.store()
        try first.begin(day: day, frames: 5, photos: [1, 2, 3])
        try first.writeDay(day, Data("{}".utf8))
        try first.finish(day: day)
        try first.begin(day: "2026/2026-09-30", frames: 2, photos: [4])

        let second = root.store()                           // a new object over the same folder
        #expect(second.isSaved(day))
        #expect(!second.isSaved("2026/2026-09-30"))
        #expect(second.records.map(\.day) == [day, "2026/2026-09-30"])
        #expect(second.record(for: day)?.photos == [1, 2, 3])
        #expect(second.bytes(of: day) == 2)
    }

    @Test func totalBytesCountsEveryFileOnce() throws {
        let root = TempRoot()
        let store = root.store()
        #expect(store.totalBytes == 0)
        try store.writeImage(Data(count: 1000), kind: .view, id: 1)
        try store.writeImage(Data(count: 500), kind: .af, id: 1)
        try store.writeDays(Data(count: 20))
        #expect(store.totalBytes == 1520)
    }

    @Test func removingADayKeepsThePicturesAnotherDayUses() throws {
        let root = TempRoot()
        let store = root.store()
        let other = "2026/2026-09-30"
        for (name, photos) in [(day, [1, 2]), (other, [2, 3])] {
            try store.begin(day: name, frames: 2, photos: photos)
            try store.writeDay(name, Data("x".utf8))
            for id in photos {
                for kind in OfflineImageKind.allCases { try store.writeImage(Data("p".utf8), kind: kind, id: id) }
            }
            try store.finish(day: name)
        }
        store.remove(day)
        #expect(!store.isSaved(day))
        #expect(store.readDay(day) == nil)
        #expect(!store.hasImage(.view, id: 1))              // only the first day used it
        #expect(!store.hasImage(.af, id: 1))
        #expect(store.hasImage(.view, id: 2))               // the second day still does
        #expect(store.hasImage(.thumb, id: 3))
        #expect(store.isSaved(other))
        #expect(root.store().isSaved(other) && !root.store().isSaved(day))   // and it was written down
        store.remove(other)
        #expect(!store.hasImage(.thumb, id: 3))             // and now nobody does
        #expect(store.records.isEmpty)
    }

    @Test func removeAllEmptiesTheFolder() throws {
        let root = TempRoot()
        let store = root.store()
        try store.writeDays(Data("d".utf8))
        try store.begin(day: day, frames: 1, photos: [1])
        try store.writeDay(day, Data("x".utf8))
        try store.writeImage(Data("p".utf8), kind: .thumb, id: 1)
        try store.finish(day: day)
        store.removeAll()
        #expect(store.readDays() == nil)
        #expect(store.savedDays.isEmpty)
        #expect(store.records.isEmpty)
        #expect(store.totalBytes == 0)
        #expect(FileManager.default.fileExists(atPath: root.url.path))
        #expect(root.store().records.isEmpty)
    }

    @Test func picturesOfAStoppedFetchAreOrphansUntilTheirDayIsRecorded() throws {
        let root = TempRoot()
        let store = root.store()
        try store.writeImage(Data("p".utf8), kind: .view, id: 9)          // no record names photo 9
        try store.writeImage(Data("p".utf8), kind: .af, id: 9)
        try store.writeDay("2026/2026-01-01", Data("x".utf8))             // nor this day
        try store.begin(day: day, frames: 1, photos: [1])                 // photo 1 is expected
        try store.writeDay(day, Data("x".utf8))
        try store.writeImage(Data("p".utf8), kind: .thumb, id: 1)
        store.removeOrphans()
        #expect(!store.hasImage(.view, id: 9))
        #expect(!store.hasImage(.af, id: 9))
        #expect(store.readDay("2026/2026-01-01") == nil)
        #expect(store.hasImage(.thumb, id: 1))
        #expect(store.readDay(day) != nil)
    }
}
