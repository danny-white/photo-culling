import Testing
@testable import CullingBayCore

@Suite("CropBox")
struct CropBoxTests {
    @Test func parsesTheServersHeader() throws {
        let c = try #require(CropBox(header: "3376,2052,1200,1200 of 7952x5304"))
        #expect(c.box == Rect(x: 3376, y: 2052, width: 1200, height: 1200))
        #expect(c.sourceSize == Size(width: 7952, height: 5304))
    }

    @Test func rejectsAnythingElse() {
        #expect(CropBox(header: nil) == nil)
        #expect(CropBox(header: "") == nil)
        #expect(CropBox(header: "1,2,3 of 10x10") == nil)
        #expect(CropBox(header: "1,2,3,4 of 0x10") == nil)
        #expect(CropBox(header: "a,b,c,d of 10x10") == nil)
    }
}
