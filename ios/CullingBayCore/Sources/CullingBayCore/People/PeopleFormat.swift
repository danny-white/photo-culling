import Foundation

/// The words of the People screens, and the one rule about names. Pure, so a test can pin them.
public enum PeopleFormat {
    /// The server takes names of 1 to 80 characters once trimmed.
    public static let maxNameLength = 80

    /// The name as it will be sent: trimmed. Nil when it is empty or longer than 80 characters.
    public static func cleanName(_ text: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...maxNameLength).contains(name.count) ? name : nil
    }

    /// `"37 photos · 5 days"`, under a group's picture.
    public static func groupCaption(_ group: FaceGroup, locale: Locale = .current) -> String {
        "\(GalleryFormat.photoCount(group.photos, locale: locale)) · \(GalleryFormat.dayCount(group.days))"
    }

    /// `"Alex?"` for a group that looks like a person, else its caption.
    public static func groupLabel(_ group: FaceGroup, locale: Locale = .current) -> String {
        group.maybe.map { "\($0.name)?" } ?? groupCaption(group, locale: locale)
    }

    /// `"Finding faces… 8,609 of 43,195 photos"` while photos are still being checked, else nil.
    public static func progress(checked: Int, of total: Int, locale: Locale = .current) -> String? {
        guard total > 0, checked < total else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        func grouped(_ n: Int) -> String { formatter.string(from: NSNumber(value: n)) ?? String(n) }
        return "Finding faces… \(grouped(checked)) of \(grouped(total)) photos"
    }

    /// `"Review 12 suggestions"`, `"Review 1 suggestion"`.
    public static func reviewTitle(_ suggestions: Int) -> String {
        "Review \(suggestions) suggestion" + (suggestions == 1 ? "" : "s")
    }

    /// `"Removed Alex from this photo"`, the toast after "Not Alex" on a tile.
    public static func removedFromPhoto(_ name: String) -> String {
        "Removed \(name) from this photo"
    }

    /// The toast when "Not Alex" finds no face of Alex's in the photo.
    public static func notInPhoto(_ name: String) -> String {
        "\(name)’s face isn’t in this photo. Use Show faces to fix it."
    }

    /// The review sheet's Confirm button: `"Confirm 58 as Alex"`, `"Confirm 56 as Alex, 2 not"`, and when
    /// every face is no, `"Confirm 8 as not Alex"`.
    public static func reviewConfirm(yes: Int, no: Int, name: String) -> String {
        if yes == 0 && no > 0 { return "Confirm \(no) as not \(name)" }
        let base = "Confirm \(yes) as \(name)"
        return no > 0 ? "\(base), \(no) not" : base
    }

    /// `"Removed Alex from 12 photos"`, the toast after "Not Alex" on a selection of photos. When some
    /// of the selected photos had none of their face, they are counted after it: `" (2 didn’t have
    /// Alex’s face)"`.
    public static func removedFromPhotos(_ name: String, photos: Int, skipped: Int) -> String {
        var text = "Removed \(name) from \(photos) photo" + (photos == 1 ? "" : "s")
        if skipped > 0 { text += " (\(skipped) didn’t have \(name)’s face)" }
        return text
    }

    /// The toast when "Not Alex" on a selection finds no face of Alex's in any of the photos.
    public static func notInPhotos(_ name: String) -> String {
        "None of these photos have \(name)’s face. Use Show faces to fix one."
    }

    /// `"31 photos"` under a person's name.
    public static func personCaption(_ person: Person, locale: Locale = .current) -> String {
        GalleryFormat.photoCount(person.photos, locale: locale)
    }
}

/// The sentences a People screen shows when a write fails.
enum PeopleMessages {
    static let nameLength = "A name needs 1 to \(PeopleFormat.maxNameLength) characters."
    static let busy = "Still saving the last change. Try again in a moment."

    static func failure(_ error: any Error) -> String {
        if let taken = error as? PersonNameTaken {
            return "“\(taken.existing.name)” is already someone."
        }
        guard let error = error as? CullingBayError else {
            return "Couldn’t save that: \(error.localizedDescription)"
        }
        switch error {
        case .transport(ServerLink.forcedMessage):
            return "Work offline is on. Turn it off to change people."
        case .transport:
            return "Can’t reach the photo server. Is the PC on and in Ubuntu?"
        case .http(404, _):
            return "That person or face isn’t there any more."
        case .http(let status, let message):
            return "Couldn’t save that: \(message ?? "HTTP \(status)")"
        case .conflict(let message, _), .unavailable(let message):
            return "Couldn’t save that: \(message ?? "the server refused")"
        case .decoding(let message):
            return "Couldn’t save that: \(message)"
        }
    }
}

/// What a write that names someone came to: it worked, the name was already someone's (so the
/// screen can offer to use that person), or it failed and the model's `message` says why.
public enum PersonWrite: Sendable, Hashable {
    case saved(Person)
    case taken(Person)
    case failed
}
