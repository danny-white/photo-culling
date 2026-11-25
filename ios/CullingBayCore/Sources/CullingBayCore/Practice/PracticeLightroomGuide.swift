import Foundation

/// The words of the "Already in Lightroom on your phone" card on a challenge screen, built from what
/// the server read from Lightroom Classic's catalog (`PracticeChallenge.lightroom`). Pure, so a test
/// can pin them and the view only lays them out. Nothing here asks anything of Lightroom or the
/// network: it only reads what the challenge already carries.
public struct PracticeLightroomGuide: Sendable, Hashable {
    /// What the challenge screen shows where the download buttons used to be.
    public enum Plan: Sendable, Hashable {
        /// Nobody checked (no `lightroom`), or the challenge is done on the Mac: the download block,
        /// as before.
        case download
        /// Checked, and the photo is in no synced album: the download block, under this line.
        case downloadWithNote(String)
        /// In synced albums: the card, with the download behind a tap.
        case inLightroom(PracticeLightroomGuide)
    }

    /// A run of a step's text; `bold` for the album and the photo, which are what to look for.
    public struct Piece: Sendable, Hashable {
        public let text: String
        public let bold: Bool

        public init(_ text: String, bold: Bool = false) {
            self.text = text
            self.bold = bold
        }
    }

    /// One numbered step of how to find the photo.
    public struct Step: Sendable, Hashable {
        public let number: Int
        public let pieces: [Piece]

        /// `"2. Go to Albums and open Sun Peaks."`, which is also what VoiceOver reads.
        public var text: String { "\(number). " + pieces.map(\.text).joined() }
    }

    /// The card's heading.
    public static let title = "Already in Lightroom on your phone"

    /// `"It's in your synced albums Sun Peaks, 3+, Edited and Picked, so you can edit it there without
    /// downloading anything. Edits you make on the phone go straight to the original in Lightroom
    /// Classic."`
    public let body: String
    /// How to find the photo, in order.
    public let steps: [Step]
    /// Shown when Lightroom Classic already has edits on the photo; nil otherwise.
    public let warning: String?
    /// `"Checked against Lightroom Classic on Wed, Nov 25 2026."`; nil when the date is missing or
    /// cannot be read.
    public let footnote: String?
    /// The row that opens the download: `"Download the RAW instead"`.
    public let downloadTitle: String

    /// The warning as VoiceOver reads it, so it comes across as a warning without the icon.
    public var spokenWarning: String? { warning.map { "Warning. \($0)" } }

    // MARK: The plan

    /// What the screen shows for a challenge. A Needs Desktop challenge is done on the Mac and has no
    /// download block, so it gets neither the card nor the line; its on-the-go version does.
    public static func plan(for challenge: PracticeChallenge) -> Plan {
        guard !challenge.needsDesktop, let lightroom = challenge.lightroom else { return .download }
        let albums = lightroom.albums.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !albums.isEmpty else { return .downloadWithNote(notOnPhoneLine(challenge.photo)) }
        return .inLightroom(PracticeLightroomGuide(photo: challenge.photo, lightroom: lightroom, albums: albums))
    }

    /// The line above the download block for a photo that is in no synced album.
    public static func notOnPhoneLine(_ photo: Photo) -> String {
        "This photo isn't in any of your synced Lightroom albums, so download the \(what(photo)) to edit it on the phone."
    }

    // MARK: Pieces of wording

    /// `"Sun Peaks, 3+, Edited and Picked"`; `"A and B"` for two, the name alone for one.
    public static func albumList(_ albums: [String]) -> String {
        guard let last = albums.last else { return "" }
        guard albums.count > 1 else { return last }
        return albums.dropLast().joined(separator: ", ") + " and " + last
    }

    /// `"Sat, Jan 18 2025"` from Lightroom's `2025-01-18T13:13:02`. Only the day is read, so no time
    /// zone can move it; Lightroom's own day can differ from the one Culling Bay shows. nil when the
    /// text is missing or does not start with a real `YYYY-MM-DD`.
    public static func longDay(_ stamp: String?) -> String? {
        guard let day = stamp.map({ String($0.prefix(10)) }), parseISODate(day) != nil else { return nil }
        return GalleryFormat.longDate(day)
    }

    /// `"DSC03308"`: how Lightroom names the photo, which is the file name from the challenge's own
    /// photo without its extension.
    public static func fileName(_ photo: Photo) -> String {
        CullFormat.stem(photo.file)
    }

    /// `"Sat, Jan 18 2025 · DSC03308"`: the photo to look for, its date left off when it is not known.
    public static func photoLabel(captured: String?, photo: Photo) -> String {
        [longDay(captured), fileName(photo)].compactMap { $0 }.joined(separator: " · ")
    }

    /// Whether to show the warning that Lightroom Classic already has edits on the photo.
    public static func showsEditedWarning(_ lightroom: PracticeLightroom) -> Bool { lightroom.edited }

    public static let editedWarning =
        "This photo already has edits. Anything you change on the phone changes it in Lightroom Classic too."

    /// `"Checked against Lightroom Classic on Wed, Nov 25 2026."`
    public static func footnote(checked: String?) -> String? {
        longDay(checked).map { "Checked against Lightroom Classic on \($0)." }
    }

    /// `"RAW"` or, for a photo that is not a RAW, `"original"`, as the save button says it.
    private static func what(_ photo: Photo) -> String { photo.raw ? "RAW" : "original" }

    private init(photo: Photo, lightroom: PracticeLightroom, albums: [String]) {
        let find = (lightroom.findIn?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            ?? albums[0]
        let list = Self.albumList(albums)
        body = "It's in your synced \(albums.count == 1 ? "album" : "albums") \(list), so you can edit it there "
            + "without downloading anything. Edits you make on the phone go straight to the original in "
            + "Lightroom Classic."
        steps = [
            [Piece("Open Lightroom.")],
            [Piece("Go to Albums and open "), Piece(find, bold: true), Piece(".")],
            [
                Piece("Find "), Piece(Self.photoLabel(captured: lightroom.captured, photo: photo), bold: true),
                Piece(", the photo at the top of this page. In a big album, sort by capture date."),
            ],
            [Piece("Edit with only the tools above, then come back and mark it done.")],
        ].enumerated().map { Step(number: $0.offset + 1, pieces: $0.element) }
        warning = Self.showsEditedWarning(lightroom) ? Self.editedWarning : nil
        footnote = Self.footnote(checked: lightroom.checked)
        downloadTitle = "Download the \(Self.what(photo)) instead"
    }
}
