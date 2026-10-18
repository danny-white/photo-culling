import Foundation
import Testing
@testable import CullingBayCore

@Suite("Save plan")
struct SavePlanTests {
    let client = CullingBayClient(baseURL: testBaseURL, transport: fixedTransport())

    private let mixed = [
        galleryPhoto(1, file: "DSC00001.ARW", raw: true, bytes: 43_100_672),
        galleryPhoto(2, file: "IMG_0002.JPG"),
        galleryPhoto(3, file: "DSC00003.NEF", raw: true, bytes: nil),
        galleryPhoto(4, file: "IMG_0004.HEIC", bytes: 2_000_000),
    ]

    @Test func aRawChoiceIsNeededOnlyWhenThereIsARaw() {
        #expect(SavePlan.needsRawChoice(mixed))
        #expect(SavePlan.needsRawChoice([mixed[0]]))
        #expect(!SavePlan.needsRawChoice([mixed[1], mixed[3]]))
        #expect(!SavePlan.needsRawChoice([]))
    }

    @Test func choosingJPEGSavesAPictureForEveryPhoto() {
        let items = SavePlan.items(for: mixed, rawChoice: .jpeg, client: client)
        #expect(items.map(\.photoID) == [1, 2, 3, 4])
        #expect(items.allSatisfy { $0.kind == .picture })
        #expect(items.map(\.filename) == ["DSC00001.jpg", "IMG_0002.JPG", "DSC00003.jpg", "IMG_0004.HEIC"])
        #expect(items.allSatisfy { $0.expectedBytes == nil })
        #expect(items[0].url.absoluteString == "http://100.82.57.4:8000/m/api/export/1")
    }

    @Test func choosingRawSavesOnlyTheRawForRawsAndThePictureForTheRest() {
        let items = SavePlan.items(for: mixed, rawChoice: .raw, client: client)
        #expect(items.map(\.kind) == [.raw, .picture, .raw, .picture])
        #expect(items.map(\.filename) == ["DSC00001.ARW", "IMG_0002.JPG", "DSC00003.NEF", "IMG_0004.HEIC"])
        #expect(items.map(\.expectedBytes) == [43_100_672, nil, nil, nil])
        #expect(items[0].url.absoluteString == "http://100.82.57.4:8000/m/api/export/1?s=original")
        #expect(items[1].url.absoluteString == "http://100.82.57.4:8000/m/api/export/2")
    }

    @Test func oneItemPerPhotoWithNoDuplicateRawAndJpeg() {
        for choice in [RawChoice.jpeg, .raw] {
            let items = SavePlan.items(for: mixed, rawChoice: choice, client: client)
            #expect(items.count == mixed.count)
            #expect(Set(items.map(\.photoID)).count == mixed.count)
        }
    }

    @Test func aListWithoutRawsIgnoresTheChoice() {
        let plain = [mixed[1], mixed[3]]
        #expect(
            SavePlan.items(for: plain, rawChoice: .raw, client: client)
                == SavePlan.items(for: plain, rawChoice: .jpeg, client: client))
        #expect(SavePlan.items(for: [], rawChoice: .raw, client: client).isEmpty)
    }

    // MARK: Progress

    @Test func progressSummarisesASuccess() {
        var progress = SaveProgress(total: 3)
        #expect(!progress.isFinished)
        #expect(progress.summary == "Saving 1 of 3…")
        progress.recordSaved()
        progress.recordSaved()
        #expect(progress.summary == "Saving 3 of 3…")
        #expect(progress.fraction == 2.0 / 3.0)
        progress.recordSaved()
        #expect(progress.isFinished)
        #expect(progress.summary == "Saved 3 photos")
        #expect(progress.fraction == 1)
    }

    @Test func progressSummarisesFailures() {
        var progress = SaveProgress(total: 3)
        progress.recordSaved()
        progress.recordFailed(42)
        progress.recordSaved()
        #expect(progress.failed == [42])
        #expect(progress.processed == 3)
        #expect(progress.summary == "Saved 2 of 3 — 1 failed")
        var none = SaveProgress(total: 2)
        none.recordFailed(1)
        none.recordFailed(2)
        #expect(none.summary == "Saved 0 of 2 — 2 failed")
    }

    @Test func oneSavedPhotoIsSingular() {
        var progress = SaveProgress(total: 1)
        progress.recordSaved()
        #expect(progress.summary == "Saved 1 photo")
        #expect(SaveProgress(total: 0).isFinished)
    }
}
