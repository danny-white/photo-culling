# CullingBayCore

The non-UI core of the Culling Bay iPhone app: Codable models for the photo server's
`/m/api` JSON, an async client with an in-memory ETag cache, picture/crop/save URL builders,
a `Server-Timing` parser, a best-effort perf reporter, and the zoom-to-full-resolution tile
maths. No UIKit, SwiftUI, CoreGraphics or third-party dependencies, so it builds on Linux and
macOS alike. The API it follows is `review/API.md`.

## Build and test

Linux (Swift 6.x toolchain; here via swiftly):

```sh
. ~/.local/share/swiftly/env.sh
cd ios/CullingBayCore
swift build
swift test
```

macOS (Xcode 16+ / Swift 6): the same `swift build` and `swift test` from the package folder,
or open `Package.swift` in Xcode. The package declares iOS 18 and macOS 15.

## Live tests

`swift test` runs only offline tests (fake transport, synthetic JSON). Tests against the
real server run when `CB_LIVE_URL` is set, otherwise they are skipped:

```sh
CB_LIVE_URL=http://100.82.57.4:8000 swift test
```

They only send GET requests. Nothing in the tests posts to the server, `/m/api/perf`
included, because that writes to the real logs.

## Layout

- `Models.swift`, `Place.swift`: `Day`, `Photo`, `PhotoList`, `GalleryDay`, `town(_:)`
- `CullModels.swift`: the Cull tab's models (`CullDay`, `Stack`, `Frame`, `Decision`, `LightroomState`, `DaySearchResult`, write bodies and answers) and the open enums (`StackKind`, `CullFlag`, `CullVia`, `DecisionState`) whose unknown values decode as `.other`
- `CullingBayClient.swift`: the client actor, `Fetched`, `ImageSize`, `SaveKind`, URL builders, and the JSON write path (never cached)
- `CullingBayClient+Cull.swift`: `cullDay`, `daySearch`, `dayLike`, and the writes `decide`, `undo`, `saveProgress`, `send`, `reset`
- `HTTPTransport.swift`, `Errors.swift`: the network seam and `CullingBayError` (including `.conflict` and `.unavailable` for a write's 409 and 503)
- `ServerTiming.swift`, `PerfReporter.swift`: timing header parsing and `POST /m/api/perf`
- `TilePlanner.swift`: tile planning and linked zoom, with its own `Point`, `Size`, `Rect`
- `CropBox.swift`: parses a crop's `X-Crop-Box` header, which gives the full-resolution size `TilePlanner` needs
