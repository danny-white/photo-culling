import CullingBayCore
import SwiftUI

/// The People section of the (i) sheet: one row per face in the photo, with its crop and name (or
/// Unnamed), and a menu to put a wrong answer right: Not Alex, This is…, Not a face. A change reads
/// the faces again, so the sheet shows what the server now says. It shows nothing for a photo with no
/// faces. State lives in `PhotoFacesModel`, which the sheet owns so it can be loaded before this is shown.
struct PhotoPeopleSection: View {
    let model: PhotoFacesModel
    /// Opens the "This is…" picker for a face.
    let onChoose: (PhotoFace) -> Void

    var body: some View {
        if !model.faces.isEmpty {
            Section("People") {
                ForEach(model.faces) { face in
                    row(face)
                }
                if !model.message.isEmpty {
                    Text(model.message).font(.footnote).foregroundStyle(.red)
                }
            }
        }
    }

    private func row(_ face: PhotoFace) -> some View {
        Menu {
            if let person = face.person {
                Button("Not \(person.name)", systemImage: "person.crop.circle.badge.xmark") {
                    Task { await model.notThem(face) }
                }
            }
            if let suggestion = face.suggestion {
                Button("Yes, it’s \(suggestion.name)", systemImage: "checkmark.circle") {
                    Task { await model.confirmSuggestion(face) }
                }
            }
            Button("This is…", systemImage: "person.crop.circle.badge.questionmark") { onChoose(face) }
            Button("Not a face", systemImage: "eye.slash", role: .destructive) {
                Task { await model.notAFace(face) }
            }
        } label: {
            HStack(spacing: 12) {
                FaceCircle(face: face.id).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(PhotoFacesModel.label(for: face))
                        .font(.body)
                        .foregroundStyle(face.person == nil && face.suggestion == nil ? .secondary : .primary)
                    if let note = Self.note(for: face) {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .disabled(model.isWorking)
        .accessibilityLabel(PhotoFacesModel.label(for: face))
        .accessibilityHint("Opens the choices for this face")
    }

    /// Why the name is there, when it might be wrong: the PC filed it, or only suspects it.
    private static func note(for face: PhotoFace) -> String? {
        if face.person != nil { return face.how == .auto ? "Filed by the PC" : nil }
        return face.suggestion == nil ? nil : "Might be"
    }
}
