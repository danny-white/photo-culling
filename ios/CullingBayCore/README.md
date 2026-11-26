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

## Known issues

`OfflineGapTests` holds tests for gaps the 2026-11-24 review found in the offline days, each
inside `withKnownIssue` with a comment naming the finding in `review-2026-11-24/ios.md`. They
show as known issues, not failures. When a fix lands, its test fails with "Known issue was not
recorded": drop the `withKnownIssue` wrapper and keep the test.

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
- `CullingBayClient.swift`: the client actor, `Fetched`, `ImageSize`, `SaveKind`, URL builders, the JSON write path (never cached), `warm(ids:)` (`GET /m/api/warm`, one try, 3 s, no cache, no queue), and `info(id:)` (`GET /m/api/info/<id>`, one try, 10 s, no URL cache, no queue; a 503 throws `.unavailable`, a 404 or 415 `.http` with that status; the last 64 answers are kept in memory, failures never)
- `CullingBayClient+Cull.swift`: `cullDay`, `daySearch`, `dayLike`, and the writes `decide`, `undo`, `saveProgress` (with the stack's `lead`), `send`, `reset`
- `PeopleModels.swift`: the People routes' shapes: `Person`, `PersonRef`, `FaceGroup` (`key`, an optional `maybe`), `PeopleList` (with `facesChecked` of `photosOK`), `PersonPhotos`, `GroupPhotos`, `PersonFace`, `PersonFaces`, `FaceSuggestion`, `PersonSuggestions`, `PhotoFace`, and the open enum `FaceHow` (`confirmed`, `auto`, `unnamed` for `"none"`, `.other`)
- `CullingBayClient+People.swift`: one method per People route (`people`, `personPhotos`, `groupPhotos`, `personFaces`, `suggestions(for:)`, `photoFaces`, and the writes `createPerson`, `renamePerson`, `setCover` (nil sends an explicit `null`), `addFaces`, `mergePerson`, `reviewSuggestions`, `deletePerson`, `removeFaces`, `removeGroup` (`POST /faces` with `group` and action `not`: the No to "Is this Alex?" on a group), `moveFaces`, `ignoreFaces`, `hideGroup`) and `faceURL(id:size:)` (`FaceSize` small 160 px or large 480 px). A write whose name is taken (409 with the existing person) throws `PersonNameTaken`, carrying that `Person`, instead of `.conflict`
- `HTTPTransport.swift`, `Errors.swift`: the network seam and `CullingBayError` (including `.conflict` and `.unavailable` for a write's 409 and 503)
- `ServerTiming.swift`, `PerfReporter.swift`: timing header parsing and `POST /m/api/perf`
- `TilePlanner.swift`: tile planning and linked zoom, with its own `Point`, `Size`, `Rect`
- `CropBox.swift`: parses a crop's `X-Crop-Box` header, which gives the full-resolution size `TilePlanner` needs
- `CropLoadGate.swift`: `CropLoadGate`, which lets only a couple of full-resolution crops download at once (the web's serial `CROPS` queue), cancelled callers leaving the line, so a decision's write always has a connection free
- `Gallery/GalleryFormat.swift`: the display strings (`longDate`, `shortDate`, `time`, `megabytes`, `photoCount`, `stars`, `tileDescription` for VoiceOver)
- `Gallery/LibraryIndex.swift`: days grouped into years and months, month strips, and On this day
- `Gallery/GallerySettings.swift`: the `GallerySettings` protocol with `InMemoryGallerySettings` and `UserDefaultsGallerySettings`
- `Gallery/HomeModel.swift`, `FeedModel.swift`, `ViewerModel.swift`: the Gallery screens' state as `@MainActor @Observable` models (home, one results screen, the photo viewer); the SwiftUI views only bind to them. `FeedModel.Source` also has `.person(id, name:)` and `.group(key)`, loaded from `/people/<id>` and `/people/group/<key>` with the same Best and bursts flags, so a person's photos are the same results screen, viewer and Save. `remove(_:lowersTotalBy:)` takes tiles out of the grid without asking the server and `restore(_:)` puts them back where they were (it refuses, and the caller loads instead, once the grid has been loaded again)
- `People/PeopleFormat.swift`: the words of the People screens (`cleanName` for the 1 to 80 character rule, group captions and labels, the "Finding faces…" line, the review title, the review sheet's Confirm title, and the toasts after "Not Alex" on a tile or on a selection of tiles), `PeopleMessages` (the sentences a failed write shows) and `PersonWrite` (`saved`, `taken` with the person who has the name, `failed`)
- `People/PeopleHomeModel.swift`: the People tab's first screen: the people and groups from `GET /m/api/people`, coverage, the name filter, and the empty states
- `People/PersonModel.swift`, `GroupModel.swift`: one person's header and what Danny does to them (rename with the 409 path, merge, delete, cover, and `removeFromPhoto(_:in:)`, "Not Alex" on one tile of their photo grid: it reads the faces in the photo, sends one `removeFaces` for the ones that are theirs and takes the tile out of the `FeedModel` at once, with `undoRemoval` sending `addFaces` for exactly those faces and putting the tile back; with "1/burst" on a tile stands for a whole burst whose other frames a `Photo` doesn't list, so the stack is read from the day (`cullDay`) and every frame that has their face is dealt with; `removeFromPhotos(_:in:)` is the same for a selection of tiles in one `removeFaces` write: each day is read once, the faces are read 6 at a time, all the reading is done before the write, a tile with none of their faces stays and is counted in `skippedTiles`, and one `undoRemoval` puts every tile back; `feedKey` is what makes the grid read itself again, and the tile's own removal and Undo leave it alone); one group's header and its actions (name it, add it to someone, yes or no to "Is this Alex?", hide; a no is sent as `removeGroup` and the group is read again, so its `maybe` goes). Each ends with an `ending` the view reacts to
- `People/ReviewModel.swift`: "Is this Alex?" in batches of up to 60 faces, every face yes until tapped (`markAll(no:)` turns the whole batch into no, or back into yes, and `allNo` says when it is, without sending anything), Confirm sends one `review` and loads the next batch; suggested groups answer at once (a no is `removeGroup`, and the groups are read again while the taps on the faces stay)
- `People/ManageFacesModel.swift`: a person's faces paged by 120 with multi-select, Not Alex, Move to… (an existing person, or a new one through the 409 path), Not a face, and Make cover; faces leave the grid as they are dealt with
- `People/PhotoFacesModel.swift`: the faces in one photo for the (i) sheet, with Not Alex, This is…, Yes it's Alex (for a face the server only suspects) and Not a face, reading the list again after each change
- `People/PersonPickerModel.swift`: the named people filtered by typed text, and the "New person" name when nobody has it
- `Gallery/SavePlan.swift`: what to download for a save (JPEG or RAW, decision N8) and the save's progress
- `Gallery/ImageDataLoader.swift`: picture downloads that share one request per URL and keep a memory cache limited by size
- `Gallery/PerfMarks.swift`: builds the `PerfItem`s for `viewer_first`, `viewer_photo`, `viewer_hd`, `results_ready`, `save_ready` and loader fetches
- `CullingBayClient+Crop.swift`: `probeCropURL` and `CropProbe`, which read a crop's `X-Crop-Box` header (the loader returns bodies only)
- `Gallery/ViewerZoomModel.swift`: the viewer's pinch, double-tap, pan and swipe-to-page maths in points, and the tile plan for the current zoom; `center` and `show(center:scale:)` read and set the point at the middle of the screen, for the focus check and linked zoom
- `Gallery/ExportModel.swift`: Save and Share as a model over a `PhotoExportService` that the app implements with PhotoKit and temp files; `onSuccess` is called once the save is finished or the file is ready to share (the Practice tab marks a challenge downloaded then, not when the sheet opens)
- `Gallery/ServerSettingsModel.swift`: the server address text, its validation, and the `/m/api/days` check
- `Practice/PracticeLightroomGuide.swift`: the words of the "Already in Lightroom on your phone" card on a challenge screen, from `PracticeChallenge.lightroom` (what the server read once from Lightroom Classic's catalog: the synced albums, the album to open, Lightroom's capture time, whether it has edits, the day it was checked): `plan(for:)` says whether the screen shows the card, the download block under a "not in any synced album" line, or the download block alone (no check, or a Needs Desktop challenge); it reads only what the challenge carries and asks for nothing
- `Practice/PracticeDraftStore.swift`: the `PracticeDraftStore` protocol with `InMemoryPracticeDraftStore` and `FilePracticeDraftStore` (one JSON file): where `PracticeModel` keeps notes that did not reach the server, so they survive the app being closed; a missing or garbled file is no notes
- `Cull/CullWriteStore.swift`: `CullWrite` (a decide, undo or progress write that can be replayed exactly) and the `CullWriteStore` protocol with `InMemoryCullWriteStore` and `FileCullWriteStore` (JSON in a directory the app passes, written atomically)
- `Cull/CullWriteQueue.swift`: `CullWriteQueue`, the port of the web app's `Q`/`send`/`pump`: writes go out one at a time in order, a transport error or 5xx keeps the write and retries after 4 s (or at once on `resume()`), a 4xx drops it and says why (`lastDrop`, `observeDrops`), what is waiting survives a relaunch, and `drain(timeout:)` waits for it to empty. `pendingFrameIDs`, `pendingByDay`, `pendingFramesByDay` and `isPending(frameID:)` say which decisions only the phone has so far. Also `CullSleep` and `CullClock`, so tests don't wait in real time
- `Cull/CullBoard.swift`: the rules of `app.js` as pure functions over a day's stacks and decisions (`status`, `lrMark`, `frameMark`, `firstOpen`, Lightroom clashes, the budget, the status line), with `StackStatus`, `FrameMark` and `CullStatusLine`
- `Cull/CullFormat.swift`: `stem`, `starText`, `dayTitle` (`Sat, 17 Oct 2026`) and the other small helpers the Cull strings share
- `Cull/CullCard.swift`: the plain data a view binds to: `CullCard` (badges, chip, pressed buttons, strip), `CullSummary` (counts, Lightroom lines, the lists, the goal note, the Send label), `CullBudgetBar` (the goal's bar, with `detail` and `explanation` saying what set the goal)
- `Info/PhotoInfo.swift`: `PhotoInfo`, one photo's camera details from `GET /m/api/info/<id>` (only `id` and `file` are required; an unknown key is ignored; `gps` that is not a `[lat, lon]` pair is nil, not an error), and the in-memory `PhotoInfoCache` the client keeps (64 photos, least recently used out first, nothing on disk)
- `Info/PhotoInfoFormat.swift`: the words of the (i) sheet: `shutter` (`1/2500 s`, `0.3 s`, `30 s`), `aperture`, `iso`, `focalLength` (with the full-frame view when it differs), `exposureComp`, `size`, `resolution`, `taken` (the camera's clock with no zone shift, plus `UTC−7` from the offset), `coordinates`, the `summary` line, the `sections` of `PhotoInfoRow`s (a row with no value is left out), and the `failure` sentences
- `Offline/OfflineStore.swift`: the days kept on the phone as files under one folder (days list, each day's JSON, thumbnails, 1616 px pictures and 1:1 crops by photo id, a manifest), with atomic writes, `remove(_:)` that keeps pictures another day uses, and `removeAll()`
- `Offline/ServerLink.swift`: whether the PC can be reached, for the whole app. `ServerLink` (`@MainActor @Observable`) is `checking`, `online`, `unreachable` or `forcedOffline` (Work offline, kept by a `WorkOfflineSetting`). It probes `GET /m/api/ping` on the real network with a 2.5 s limit at launch, when the app comes to the front, when the network changes, and on `checkNow()` (Try now, pull to refresh); while unreachable, active and with a network, it probes again after 5, 10 and 20 s and then every 30 s (`pollDelays`). `ServerLinkTransport` sits on the real network and reads `ServerLinkGate`, a locked snapshot: a request waits for the first probe (at most 2.5 s), fails at once with `.transport("Can't reach the PC.")` (or `"Work offline is on."`) when not online, and otherwise goes out; what comes back teaches the link (a network failure is unreachable, any HTTP answer online). `onReachable` is called when the PC can be reached again; `onWorkOffline` when Work offline is turned on
- `Offline/OfflineTransport.swift`: an `HTTPTransport` over the real one (in the app, over `ServerLinkTransport`): pictures local first, the days list and a day network first (6 s) with the saved copy served as a 200 with `X-Culling-Bay-Offline: 1` when the network fails, which the link makes instant while the PC cannot be reached; everything else passes through (writes, crops, search, the gallery, `warm`, which has its own 3 s timeout, and `info`, which is never saved and has its own 10 s)
- `Offline/OfflinePlanner.swift`: `OfflinePlanner.plan` picks the days to keep within a size limit (pinned, then partly culled, then the newest untouched) with a per-frame size estimate, `OfflinePin`, and `OfflineFormat` for the Settings words
- `Offline/OfflineDownloader.swift`: fetches one day into the store, four files at a time, skipping what is there (`warm=0` pictures, `keep=0` crops at the AF point)
- `Offline/OfflineSync.swift`: the sync loop as a `@MainActor @Observable` model that the app's `OfflineManager` wraps: the days list, then orphans deleted, then pictures for every planned day in plan order (days that leave the plan deleted before each), then the 1:1 crop top-up of the saved days, which `setCropsPaused(true)` holds back (and stops, if it is running) while a day is open in the Cull tab, and `setCropsPaused(false)` runs again if it was held back; how a transport error, a refusal or a file error ends it; the settle delay before a settings change syncs; a sync asked for mid-sync following it; switching off wiping the store once the fetch in flight lets go; no sync starting while `canReachPC` (the link being online) says no. It reads the days list, the store, the downloader and the settings through small protocols (`OfflineDaysSource`, `OfflineSyncStore`, `OfflineDayDownloading`, `OfflineSettingsSource`), so tests run it against fakes
- `Cull/CullDaysModel.swift`: the Cull tab's home as a `@MainActor @Observable` model: days grouped as In progress, On this day and by year and month, a debounced day search whose hits pass their match ids on, each row's bar (`pcFraction`, the PC's decided share, and, laid over by `row(_:pending:)` from the write queue, `phoneFraction`, what only the phone has decided, without counting twice a frame the day's saved copy shows decided, `OfflineStore.decidedFrames`), and `returnTarget`, which says where the list goes when it comes back from a day (the day's row may have moved into or out of In progress)
- `Cull/CullSessionModel.swift`: one opened day: opening with matches first, `reject()`, `keepAll()`, `keep(stars:)`, `undo()` (with the 409 rollback), `go(_:)`, debounced progress saves (none while browsing the matches of a day opened from a search; a decision still saves), `send()` (which says "Turn off Work offline to send." at once while Work offline is on), `refresh()`, the toast (and `Toast.lifetime`, which keeps one with Undo up while VoiceOver runs), `explainGoal()` (a toast saying what the day's goal is based on, from `Budget.basis`) and the feedback event, and the burst picker (`openPicker`, `keepPicked`, `closePicker`) and the 1:1 focus check (`openFocus`, `closeFocus`) that open over the cards; whenever the card on screen changes it hands the frame a 1:1 check would open, and the next card's, to its `CullWarmer`; the grid, rescue, drop and Start over are not here yet
- `Cull/CullPickerModel.swift`: the burst picker of `app.js` as a `@MainActor @Observable` model: a filmstrip for up to six frames (tick, stars, swipe) or a knock-out grid for more, what a decided burst starts with, and the `keeps` and `keepRates` that a keep saves as one tap by `.burst`. `CullPickerFrame` is what a thumbnail and the big frame show. When the frame on the big picture changes it hands that frame and the next one in the strip to the session's `CullWarmer`
- `Cull/CullWarmer.swift`: `CullWarmer` asks the PC (`CullingBayClient.warm`, `GET /m/api/warm`) to decode the RAWs a 1:1 check will want, for cards the phone shows from its own saved copy, whose pictures never reach the PC to start that decode themselves. Fire and forget (a failure is ignored and the frames are tried again later), 150 ms after the last change so a fast swipe asks only for the card it stops on, never a frame already asked for (the last 16 are kept, as many as the PC keeps decoded), not while the write queue is offline, and only for RAW file names
- `Cull/CullFocusModel.swift`: the 1:1 focus check: the frame and its start point (AF point, tap, or middle), stepping between a burst's frames, and linked zoom (`TilePlanner.linkedZoom`) that carries the point and the source pixels per point from one frame to the next. Also `imagePoint`, the AF box size and `Frame.afPoint`
