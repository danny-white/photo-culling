import Foundation
import Testing
@testable import CullingBayCore

@Suite("ServerTiming")
struct ServerTimingTests {
    @Test func parsesTheServersExampleHeader() throws {
        let header = #"total;dur=59.2, load;dur=49.7, resize;dur=2.7, cache;desc="miss", ext;desc=".arw""#
        let timing = try #require(ServerTiming.parse(header))
        #expect(timing.entries == [
            .init(name: "total", dur: 59.2),
            .init(name: "load", dur: 49.7),
            .init(name: "resize", dur: 2.7),
            .init(name: "cache", desc: "miss"),
            .init(name: "ext", desc: ".arw"),
        ])
        #expect(timing.total == 59.2)
        #expect(timing.dur(of: "load") == 49.7)
        #expect(timing.desc(of: "cache") == "miss")
        #expect(timing.desc(of: "ext") == ".arw")
        #expect(timing.dur(of: "cache") == nil)
        #expect(timing.entry(named: "nope") == nil)
    }

    @Test func parsesTheDaysHeader() throws {
        let timing = try #require(ServerTiming.parse(
            #"total;dur=489.1, receipts;dur=8.3, days_rebuild;dur=441.2, days_cache;desc="miss""#))
        #expect(timing.entries.map(\.name) == ["total", "receipts", "days_rebuild", "days_cache"])
        #expect(timing.total == 489.1)
        #expect(timing.desc(of: "days_cache") == "miss")
    }

    @Test func preservesOrderAndDuplicates() throws {
        let timing = try #require(ServerTiming.parse("b;dur=2, a;dur=1, b;dur=3"))
        #expect(timing.entries.map(\.name) == ["b", "a", "b"])
        #expect(timing.dur(of: "b") == 2)
    }

    @Test func toleratesExtraSpaces() throws {
        let timing = try #require(ServerTiming.parse("  total ;  dur = 12.5  ,   load;dur=3 ;desc = \" hit \"  "))
        #expect(timing.total == 12.5)
        #expect(timing.entry(named: "load") == .init(name: "load", dur: 3, desc: " hit "))
    }

    @Test func descMayBeQuotedOrUnquoted() throws {
        let timing = try #require(ServerTiming.parse(#"a;desc="hit", b;desc=miss, c;desc=".arw""#))
        #expect(timing.desc(of: "a") == "hit")
        #expect(timing.desc(of: "b") == "miss")
        #expect(timing.desc(of: "c") == ".arw")
    }

    @Test func quotedDescMayContainCommasSemicolonsAndEscapes() throws {
        let timing = try #require(ServerTiming.parse(#"a;desc="x, y; z";dur=4, b;desc="say \"hi\"""#))
        #expect(timing.entries.count == 2)
        #expect(timing.entry(named: "a") == .init(name: "a", dur: 4, desc: "x, y; z"))
        #expect(timing.desc(of: "b") == #"say "hi""#)
    }

    @Test func missingPartsAreNil() throws {
        let timing = try #require(ServerTiming.parse("bare, total;dur=, odd;dur=abc, nodesc;desc, empty;desc="))
        #expect(timing.entry(named: "bare") == .init(name: "bare"))
        #expect(timing.dur(of: "total") == nil)
        #expect(timing.dur(of: "odd") == nil)
        #expect(timing.desc(of: "nodesc") == nil)
        #expect(timing.desc(of: "empty") == "")
        #expect(timing.entries.count == 5)
    }

    @Test func parameterNamesAreCaseInsensitiveAndEntryLookupToo() throws {
        let timing = try #require(ServerTiming.parse("Total;DUR=7;Desc=x"))
        #expect(timing.total == 7)
        #expect(timing.desc(of: "TOTAL") == "x")
    }

    @Test func nonFiniteDurationsAreRejected() throws {
        let timing = try #require(ServerTiming.parse("a;dur=nan, b;dur=inf, c;dur=-5"))
        #expect(timing.dur(of: "a") == nil)
        #expect(timing.dur(of: "b") == nil)
        #expect(timing.dur(of: "c") == -5)
    }

    @Test func firstDurAndDescWin() throws {
        let timing = try #require(ServerTiming.parse("a;dur=1;dur=2;desc=x;desc=y"))
        #expect(timing.entry(named: "a") == .init(name: "a", dur: 1, desc: "x"))
    }

    @Test func garbageDoesNotCrashAndYieldsNothingUseful() {
        for header in ["", "   ", ",,,", ";;;", "=", "dur=5", ";dur=5", "\"", "a;desc=\"unterminated, b;dur=3"] {
            let timing = ServerTiming(header: header)
            #expect(timing.total == nil, "\(header)")
        }
        #expect(ServerTiming.parse(nil) == nil)
        #expect(ServerTiming.parse("") == nil)
        #expect(ServerTiming.parse(",;=,") == nil)
    }

    @Test func skipsBadEntriesButKeepsGoodOnes() throws {
        let timing = try #require(ServerTiming.parse("dur=5, total;dur=9, =x, ,load;dur=2"))
        #expect(timing.entries.map(\.name) == ["total", "load"])
    }

    @Test func unterminatedQuoteTakesTheRestOfTheHeader() throws {
        let timing = try #require(ServerTiming.parse(#"a;desc="oops, b;dur=3"#))
        #expect(timing.entries.count == 1)
        #expect(timing.desc(of: "a") == "oops, b;dur=3")
    }
}
