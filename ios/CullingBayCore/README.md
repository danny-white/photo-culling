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
- `CullingBayClient+Cull.swift`: `cullDay`, `daySearch`, `dayLike`, and the writes `decide`, `undo`, `saveProgress` (with the stack's `lead`), `send`, `reset`
- `HTTPTransport.swift`, `Errors.swift`: the network seam and `CullingBayError` (including `.conflict` and `.unavailable` for a write's 409 and 503)
- `ServerTiming.swift`, `PerfReporter.swift`: timing header parsing and `POST /m/api/perf`
- `TilePlanner.swift`: tile planning and linked zoom, with its own `Point`, `Size`, `Rect`
- `CropBox.swift`: parses a crop's `X-Crop-Box` header, which gives the full-resolution size `TilePlanner` needs
- `CropLoadGate.swift`: `CropLoadGate`, which lets only a couple of full-resolution crops download at once (the web's serial `CROPS` queue), cancelled callers leaving the line, so a decision's write always has a connection free
- `Gallery/GalleryFormat.swift`: the display strings (`longDate`, `shortDate`, `time`, `megabytes`, `photoCount`, `stars`)
- `Gallery/LibraryIndex.swift`: days grouped into years and months, month strips, and On this day
- `Gallery/GallerySettings.swift`: the `GallerySettings` protocol with `InMemoryGallerySettings` and `UserDefaultsGallerySettings`
- `Gallery/HomeModel.swift`, `FeedModel.swift`, `ViewerModel.swift`: the Gallery screens' state as `@MainActor @Observable` models (home, one results screen, the photo viewer); the SwiftUI views only bind to them
- `Gallery/SavePlan.swift`: what to download for a save (JPEG or RAW, decision N8) and the save's progress
- `Gallery/ImageDataLoader.swift`: picture downloads that share one request per URL and keep a memory cache limited by size
- `Gallery/PerfMarks.swift`: builds the `PerfItem`s for `viewer_first`, `viewer_photo`, `viewer_hd`, `results_ready`, `save_ready` and loader fetches
- `CullingBayClient+Crop.swift`: `probeCropURL` and `CropProbe`, which read a crop's `X-Crop-Box` header (the loader returns bodies only)
- `Gallery/ViewerZoomModel.swift`: the viewer's pinch, double-tap, pan and swipe-to-page maths in points, and the tile plan for the current zoom; `center` and `show(center:scale:)` read and set the point at the middle of the screen, for the focus check and linked zoom
- `Gallery/ExportModel.swift`: Save and Share as a model over a `PhotoExportService` that the app implements with PhotoKit and temp files
- `Gallery/ServerSettingsModel.swift`: the server address text, its validation, and the `/m/api/days` check
- `Cull/CullWriteStore.swift`: `CullWrite` (a decide, undo or progress write that can be replayed exactly) and the `CullWriteStore` protocol with `InMemoryCullWriteStore` and `FileCullWriteStore` (JSON in a directory the app passes, written atomically)
- `Cull/CullWriteQueue.swift`: `CullWriteQueue`, the port of the web app's `Q`/`send`/`pump`: writes go out one at a time in order, a transport error or 5xx keeps the write and retries after 4 s (or at once on `resume()`), a 4xx drops it and says why (`lastDrop`, `observeDrops`), what is waiting survives a relaunch, and `drain(timeout:)` waits for it to empty. Also `CullSleep` and `CullClock`, so tests don't wait in real time
- `Cull/CullBoard.swift`: the rules of `app.js` as pure functions over a day's stacks and decisions (`status`, `lrMark`, `frameMark`, `firstOpen`, Lightroom clashes, the budget, the status line), with `StackStatus`, `FrameMark` and `CullStatusLine`
- `Cull/CullFormat.swift`: `stem`, `starText`, `dayTitle` (`Sat, 17 Oct 2026`) and the other small helpers the Cull strings share
- `Cull/CullCard.swift`: the plain data a view binds to: `CullCard` (badges, chip, pressed buttons, strip), `CullSummary` (counts, Lightroom lines, the lists, the budget note, the Send label), `CullBudgetBar`
- `Cull/CullDaysModel.swift`: the Cull tab's home as a `@MainActor @Observable` model: days grouped as In progress, On this day and by year and month, and a debounced day search whose hits pass their match ids on
- `Cull/CullSessionModel.swift`: one opened day: opening with matches first, `reject()`, `keepAll()`, `keep(stars:)`, `undo()` (with the 409 rollback), `go(_:)`, debounced progress saves, `send()`, `refresh()`, the toast and the feedback event, and the burst picker (`openPicker`, `keepPicked`, `closePicker`) and the 1:1 focus check (`openFocus`, `closeFocus`) that open over the cards; the grid, rescue, drop and Start over are not here yet
- `Cull/CullPickerModel.swift`: the burst picker of `app.js` as a `@MainActor @Observable` model: a filmstrip for up to six frames (tick, stars, swipe) or a knock-out grid for more, what a decided burst starts with, and the `keeps` and `keepRates` that a keep saves as one tap by `.burst`. `CullPickerFrame` is what a thumbnail and the big frame show
- `Cull/CullFocusModel.swift`: the 1:1 focus check: the frame and its start point (AF point, tap, or middle), stepping between a burst's frames, and linked zoom (`TilePlanner.linkedZoom`) that carries the point and the source pixels per point from one frame to the next. Also `imagePoint`, the AF box size and `Frame.afPoint`
