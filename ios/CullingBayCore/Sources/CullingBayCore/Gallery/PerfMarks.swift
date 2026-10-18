import Foundation

/// Builds the `PerfItem`s the gallery reports, with the names `review/static/m/perf-client.js`
/// and `gallery.js` use, so the phone app and the web pages land in the same timing log.
public enum PerfMarks {
    /// The thumbnail is on screen in the viewer. `name` is what was shown, see `name(of:)`.
    public static func viewerFirst(ms: Double, url: URL) -> PerfItem {
        PerfItem(type: "viewer_first", ms: ms, name: name(of: url))
    }

    /// The sharp 1616 px picture replaced it.
    public static func viewerPhoto(ms: Double, url: URL) -> PerfItem {
        PerfItem(type: "viewer_photo", ms: ms, name: name(of: url))
    }

    /// The 3000 px picture arrived after a zoom.
    public static func viewerHD(ms: Double, url: URL) -> PerfItem {
        PerfItem(type: "viewer_hd", ms: ms, name: name(of: url))
    }

    /// The first tile of a results screen is on screen.
    public static func resultsReady(ms: Double, source: FeedModel.Source, count: Int) -> PerfItem {
        PerfItem(type: "results_ready", ms: ms, screen: source.screen, n: count)
    }

    /// The first picture of the save sheet is ready; `count` photos are being saved.
    public static func saveReady(ms: Double, url: URL, count: Int) -> PerfItem {
        PerfItem(type: "save_ready", ms: ms, name: name(of: url), n: count)
    }

    /// One picture fetched from the network, the arguments of `ImageDataLoader.Report`.
    public static func fetch(url: URL, ms: Double, bytes: Int, serverTiming: ServerTiming?) -> PerfItem {
        PerfItem(
            type: "fetch", ms: ms, name: name(of: url), detail: "network", bytes: bytes,
            serverMs: serverTiming?.total)
    }

    /// The path and query, at most 300 characters, as the web pages name a request.
    public static func name(of url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return String(url.absoluteString.prefix(300))
        }
        let query = components.percentEncodedQuery.map { "?" + $0 } ?? ""
        return String((components.percentEncodedPath + query).prefix(300))
    }
}
