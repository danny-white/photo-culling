import CullingBayCore
import SwiftUI

/// One challenge (`detailView` in `practice.js`): the picture, what to do and why, saving the RAW
/// to Photos to edit in Lightroom, and marking it done with a note. A Needs Desktop challenge has
/// no save buttons: it says it is done on the Mac, and links to its on-the-go version, which is
/// the same screen for the same photo. A photo that is already in Lightroom on the phone says so and
/// says how to find it, with the save buttons behind a tap (`PracticeLightroomGuide`); that is only
/// read from the challenge, nothing is asked of Lightroom. The state lives in `PracticeModel`; what is typed in the note box is kept there too (and in a file,
/// for the next launch), so a note that did not save is still here when the screen is opened again.
@MainActor
struct PracticeDetailView: View {
    @Environment(AppServices.self) private var services
    let id: String
    @State private var note: String
    @State private var export: ExportLaunch?
    /// The "Download the RAW instead" row of the Lightroom card is open.
    @State private var showDownload = false
    /// The height of the screen, for capping a tall photo.
    @State private var screenHeight: CGFloat = 0
    @FocusState private var noteFocused: Bool

    private var model: PracticeModel { services.practice }

    /// `note` is what the note box starts with (`PracticeModel.draft(for:)`).
    init(id: String, note: String) {
        self.id = id
        _note = State(initialValue: note)
    }

    var body: some View {
        ScrollView {
            if let challenge = model.challenge(id: id) {
                content(challenge)
            } else {
                Text("That challenge is not in the list any more.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        // The scroll view's height plus the bars it runs under: the screen's.
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height + $0.safeAreaInsets.top + $0.safeAreaInsets.bottom
        } action: { screenHeight = $0 }
        .navigationTitle("Challenge")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { noteFocused = false }
            }
        }
        .sheet(item: $export) { launch in
            ExportSheet(launch: launch)
        }
        .onChange(of: note) { _, text in
            if text.count > Self.noteLimit { note = String(text.prefix(Self.noteLimit)) }
            model.setDraft(note, for: id)
        }
        // A done challenge saves its note when you leave the box or the screen.
        .onChange(of: noteFocused) { _, focused in
            if !focused { saveNoteIfDone() }
        }
        .onDisappear { saveNoteIfDone() }
    }

    /// The most the server keeps.
    private static let noteLimit = 2000

    private func content(_ challenge: PracticeChallenge) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if !model.message.isEmpty {
                PracticeMessageView(text: model.message)
            }
            ChallengePhoto(
                url: services.client.imageURL(id: challenge.photo.id, size: .view), maxHeight: screenHeight * 0.6)
                .accessibilityLabel("Challenge photo")
            header(challenge)
            brief(challenge)
            if challenge.needsDesktop {
                desktopOnly(challenge)
            } else {
                gettingThePhoto(challenge)
            }
            noteBox
            actions(challenge)
        }
        .padding(16)
    }

    // MARK: Header and brief

    private func header(_ challenge: PracticeChallenge) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(challenge.title).font(.title2.weight(.bold))
                pairing(challenge)
                let when = PracticeFormat.whenAndPlace(challenge.photo)
                if !when.isEmpty {
                    Text(when).font(.subheadline).foregroundStyle(.secondary)
                }
                let camera = challenge.photo.camera ?? ""
                Text(camera.isEmpty ? "Camera not recorded" : camera)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if challenge.wasDownloaded {
                PracticeTag(text: "Downloaded")
            }
        }
    }

    /// Under the title: for a Needs Desktop challenge its tag and the reason; for an on-the-go
    /// version a line saying so and the way back to the full one.
    @ViewBuilder
    private func pairing(_ challenge: PracticeChallenge) -> some View {
        if challenge.needsDesktop {
            VStack(alignment: .leading, spacing: 4) {
                PracticeTag(text: PracticeFormat.needsDesktopTag, accent: true)
                if let reason = challenge.desktopReason, !reason.isEmpty {
                    Text(reason).font(.subheadline)
                }
            }
            .padding(.vertical, 3)
        } else if let parent = model.parent(of: challenge.id) {
            VStack(alignment: .leading, spacing: 4) {
                Text(PracticeFormat.companionNote)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                pairLink(PracticeFormat.desktopLink, to: parent)
            }
            .padding(.vertical, 3)
        }
    }

    /// A link to the other half of a pair, with where it stands.
    private func pairLink(_ title: String, to other: PracticeChallenge) -> some View {
        NavigationLink(value: PracticeRoute(id: other.id)) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                if let status = PracticeFormat.statusTag(other) {
                    PracticeTag(text: status)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func brief(_ challenge: PracticeChallenge) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The challenge").font(.headline)
            Text("Only use:").font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(challenge.tools.enumerated()), id: \.offset) { _, tool in
                    bullet(tool)
                }
            }
            labelled("Aim for:", challenge.aim)
            labelled("Why this photo:", challenge.why)
            if !challenge.hints.isEmpty {
                DisclosureGroup("Hints") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(challenge.hints.enumerated()), id: \.offset) { _, hint in
                            bullet(hint)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
    }

    private func labelled(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.subheadline.weight(.semibold))
            Text(text).font(.subheadline)
        }
    }

    // MARK: Needs Desktop

    /// Instead of the save buttons and the phone how-to: where to do it, and the on-the-go version.
    private func desktopOnly(_ challenge: PracticeChallenge) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(PracticeFormat.desktopBox(challenge.photo))
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            if let companion = model.companions(of: challenge.id).first {
                pairLink(PracticeFormat.onTheGoLink, to: companion)
            }
        }
    }

    // MARK: Getting the RAW

    /// What comes with the download buttons depends on where the photo is in Lightroom: in a synced
    /// album, the card says so and the buttons wait behind a tap; in none, a line above them; not
    /// checked, the buttons alone.
    @ViewBuilder
    private func gettingThePhoto(_ challenge: PracticeChallenge) -> some View {
        switch PracticeLightroomGuide.plan(for: challenge) {
        case .download:
            downloads(challenge)
            howTo(challenge)
        case .downloadWithNote(let line):
            VStack(alignment: .leading, spacing: 10) {
                Text(line)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                downloads(challenge)
            }
            howTo(challenge)
        case .inLightroom(let guide):
            lightroomCard(guide, challenge)
        }
    }

    /// "Already in Lightroom on your phone": where the photo is, how to find it, a warning if it has
    /// edits, when this was checked, and the way to the download after all.
    private func lightroomCard(_ guide: PracticeLightroomGuide, _ challenge: PracticeChallenge) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(PracticeLightroomGuide.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(guide.body).font(.subheadline)
            VStack(alignment: .leading, spacing: 6) {
                Text("How to find it").font(.subheadline.weight(.semibold))
                ForEach(guide.steps, id: \.number) { step in
                    Text(attributed(step))
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(step.text)
                }
            }
            if let warning = guide.warning {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
                    Text(warning)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.footnote)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(guide.spokenWarning ?? warning)
            }
            if let footnote = guide.footnote {
                Text(footnote).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            downloadRow(guide.downloadTitle)
            if showDownload {
                downloads(challenge)
                howTo(challenge)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    /// The row that opens and closes the download. It is a button that says whether it is open, which
    /// a plain disclosure group does not tell VoiceOver outside a list.
    private func downloadRow(_ title: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showDownload.toggle() }
        } label: {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .rotationEffect(.degrees(showDownload ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .accessibilityValue(showDownload ? "Expanded" : "Collapsed")
        .accessibilityHint(showDownload ? "Hides the download buttons" : "Shows the download buttons")
    }

    /// A step with its number, and the album and the photo in bold.
    private func attributed(_ step: PracticeLightroomGuide.Step) -> AttributedString {
        var text = AttributedString("\(step.number). ")
        for piece in step.pieces {
            var run = AttributedString(piece.text)
            if piece.bold { run.inlinePresentationIntent = .stronglyEmphasized }
            text += run
        }
        return text
    }

    private func downloads(_ challenge: PracticeChallenge) -> some View {
        VStack(spacing: 10) {
            Button { start(.save, for: challenge) } label: {
                Text(PracticeFormat.saveTitle(challenge.photo)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button { start(.share, for: challenge) } label: {
                Text(PracticeFormat.shareTitle(challenge.photo)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }

    /// Opens the Save or Share for the picture, as the file itself. It counts as downloaded once
    /// the file is in Photos (or ready to share), not when the sheet opens: a refused permission,
    /// a failed download or Cancel leaves it as it was.
    private func start(_ action: ExportModel.Action, for challenge: PracticeChallenge) {
        let id = challenge.id
        let model = model
        export = services.makeExport([challenge.photo], action: action, rawChoice: .raw, onSuccess: {
            model.markDownloaded(id)
        })
    }

    private func howTo(_ challenge: PracticeChallenge) -> some View {
        let what = challenge.photo.raw ? "RAW" : "original"
        return VStack(alignment: .leading, spacing: 4) {
            Text("1. Save the \(what) to Photos.")
            Text("2. In Lightroom, tap the add-photos button and choose it from your camera roll.")
            Text("3. Edit with only the tools above, then come back and mark it done.")
            Text("Or choose Share \(what)… and pick Lightroom in the share sheet.")
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Note and status

    private var noteBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How did it go?").font(.subheadline.weight(.semibold))
            TextField("Add a short note…", text: $note, axis: .vertical)
                .lineLimit(3...8)
                .focused($noteFocused)
                .padding(10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func actions(_ challenge: PracticeChallenge) -> some View {
        let busy = model.isSaving(id)
        if challenge.status == .done {
            HStack {
                Text(PracticeFormat.doneLine(challenge)).font(.headline)
                Spacer()
                Button("Undo") { Task { await model.moveToWaiting(id) } }
                    .buttonStyle(.bordered)
                    .disabled(busy)
            }
        } else {
            HStack(spacing: 12) {
                Button { markDone() } label: {
                    Text("Mark done").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if challenge.status == .skipped {
                    Button { Task { await model.moveToWaiting(id) } } label: {
                        Text("Move to waiting").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button { Task { await model.setStatus(.skipped, for: id) } } label: {
                        Text("Skip").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.large)
            .disabled(busy)
        }
    }

    /// Marks it done with the note as typed. If that fails, the note stays in the box.
    private func markDone() {
        noteFocused = false
        let text = note
        Task { await model.setStatus(.done, for: id, note: text) }
    }

    private func saveNoteIfDone() {
        guard let challenge = model.challenge(id: id), challenge.status == .done,
              note != challenge.note
        else { return }
        let text = note
        Task { await model.saveNote(text, for: id) }
    }
}

/// The challenge's photo in a frame of its own shape, so a portrait fills a tall frame instead of
/// sitting in a 4:3 box with bars either side. The frame is 4:3 until the picture is known, and
/// no taller than `maxHeight` (a fraction of the screen) when that is set.
private struct ChallengePhoto: View {
    let url: URL
    let maxHeight: CGFloat
    @State private var shape = PracticeFormat.photoShape(width: 0, height: 0)

    var body: some View {
        RemoteImage(url: url, maxPixel: ImagePixels.view, fit: true, onSize: { size in
            shape = PracticeFormat.photoShape(width: size.width, height: size.height)
        })
        .aspectRatio(shape, contentMode: .fit)
        .frame(maxHeight: maxHeight > 0 ? maxHeight : .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity)
    }
}
