import Testing
@testable import CullingBayCore

@Suite("App version")
struct AppVersionTests {
    @Test func aScriptBuildShowsItsNumberAndCommit() {
        #expect(AppVersion.label(build: "154", revision: "975f562") == "Build 154 · 975f562")
        #expect(AppVersion.label(build: "154", revision: "975f562-dirty") == "Build 154 · 975f562-dirty")
    }

    @Test func aBuildWithoutACommitShowsTheNumberAlone() {
        #expect(AppVersion.label(build: "154", revision: nil) == "Build 154")
        #expect(AppVersion.label(build: "154", revision: " ") == "Build 154")
    }

    @Test func anXcodeBuildSaysSo() {
        #expect(AppVersion.label(build: "1", revision: "") == "Development build")
    }

    @Test func noBuildNumberShowsNothing() {
        #expect(AppVersion.label(build: nil, revision: "975f562") == nil)
        #expect(AppVersion.label(build: "", revision: nil) == nil)
    }

    @Test func itReadsTheInfoPlistKeys() {
        let info: [String: Any] = ["CFBundleVersion": "154", "CBGitRevision": "975f562"]
        #expect(AppVersion.label(info: info) == "Build 154 · 975f562")
        #expect(AppVersion.label(info: nil) == nil)
    }
}
