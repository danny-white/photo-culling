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

    private static func withSize(_ title: String, _ photo: Photo) -> String {
        let size = GalleryFormat.megabytes(photo.bytes)
        return size.isEmpty ? title : "\(title) · \(size)"
    }
}
