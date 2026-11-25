import Foundation

/// The Practice screens' display strings, ported from `practice.js`. Pure, so a test can pin them.
public enum PracticeFormat {
    /// `"~8 min"`. A row puts it after the level, which has its own colour: `Easy · ~8 min`.
    public static func minutesText(_ challenge: PracticeChallenge) -> String {
        "~\(challenge.minutes) min"
    }

    /// `"Sat, Oct 17 2026 · Greenwood"`: the day it was shot and the town, whichever are known.
    public static func whenAndPlace(_ photo: Photo) -> String {
        [photo.date.map { GalleryFormat.longDate($0) }, town(photo.place)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The primary button: `"Save RAW to Photos · 43 MB"`, or `"Save original · 3.2 MB"` for a
    /// photo that is not a RAW. The size is left off when it is not known.
    public static func saveTitle(_ photo: Photo) -> String {
        withSize(photo.raw ? "Save RAW to Photos" : "Save original", photo)
    }

    /// `"Share RAW…"`, or `"Share original…"` for a photo that is not a RAW.
    public static func shareTitle(_ photo: Photo) -> String {
        photo.raw ? "Share RAW…" : "Share original…"
    }

    /// `"Done · Sat, Nov 21 2026"`, or `"Done"` when the server gave no time.
    public static func doneLine(_ challenge: PracticeChallenge) -> String {
        let day = challenge.doneAt.map { GalleryFormat.longDate(String($0.prefix(10))) } ?? ""
        return day.isEmpty ? "Done" : "Done · \(day)"
    }

    // MARK: Needs Desktop

    /// The tag on a challenge whose full version needs Lightroom Classic.
    public static let needsDesktopTag = "Needs Desktop"

    /// The label of a companion's row.
    public static let onTheGoLabel = "On the go"

    /// The link from a Needs Desktop challenge to its companion.
    public static let onTheGoLink = "On the go version ›"

    /// The link from a companion to its Needs Desktop challenge.
    public static let desktopLink = "Full desktop version ›"

    /// Under a companion's title.
    public static let companionNote = "On the go version of a Needs Desktop challenge."

    /// `"Do this one on the Mac in Lightroom Classic. It's already in your catalog: 2024/2024-05-10 ›
    /// DSC00576.ARW."`, the box that stands in for the download buttons.
    public static func desktopBox(_ photo: Photo) -> String {
        "Do this one on the Mac in Lightroom Classic. \(catalogLine(photo))"
    }

    /// `"It's already in your catalog: 2024/2024-05-10 › DSC00576.ARW."`: the day folder and the file.
    public static func catalogLine(_ photo: Photo) -> String {
        "It's already in your catalog: \(photo.day) › \(photo.file)."
    }

    /// `"~12 min · iPhone"`, after the level on a companion's row.
    public static func companionMinutesText(_ challenge: PracticeChallenge) -> String {
        "\(minutesText(challenge)) · iPhone"
    }

    /// `"Done"` or `"Skipped"` once a challenge is finished with; nil while it is waiting.
    public static func finishedTag(_ challenge: PracticeChallenge) -> String? {
        switch challenge.status {
        case .done: "Done"
        case .skipped: "Skipped"
        case .todo, .downloaded: nil
        }
    }

    /// A companion's status tag, and the status beside a link to the other half of a pair: `"Done"`,
    /// `"Skipped"` or `"Downloaded"`; nil for a challenge nothing has happened to.
    public static func statusTag(_ challenge: PracticeChallenge) -> String? {
        if let finished = finishedTag(challenge) { return finished }
        return challenge.status == .downloaded ? "Downloaded" : nil
    }

    /// The shape of the picture's frame on the challenge screen, width over height: the picture's
    /// own once it is known, and 4:3 until then (or when it reports no size).
    public static func photoShape(width: Double, height: Double) -> Double {
        width > 0 && height > 0 ? width / height : 4.0 / 3.0
    }

    private static func withSize(_ title: String, _ photo: Photo) -> String {
        let size = GalleryFormat.megabytes(photo.bytes)
        return size.isEmpty ? title : "\(title) · \(size)"
    }
}
