import CullingBayCore
import SwiftUI
import UIKit

/// One Save or Share, ready to show in an `ExportSheet`.
struct ExportLaunch: Identifiable {
    let id = UUID()
    let model: ExportModel
}

/// The sheet for saving photos to the library, or sharing one (decision N8). A RAW asks once
/// whether to use the JPEG or the RAW; then the download runs with its progress, and a denied
/// Photos permission says so with a button to Settings.
@MainActor
struct ExportSheet: View {
    let model: ExportModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var choice: RawChoice?
    @State private var showsShareSheet = false

    init(launch: ExportLaunch) {
        model = launch.model
    }

    private var isFinished: Bool { model.hasStarted && !model.isRunning }
    private var succeeded: Bool {
        isFinished && model.action == .save && !model.permissionDenied
            && model.progress.isFinished && model.progress.failed.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                if model.needsChoice {
                    rawChoice
                } else {
                    progress
                }
                Spacer(minLength: 0)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationTitle(model.action == .save ? "Save to phone" : "Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isFinished ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        // Dismissing the sheet cancels this, and the download stops with it.
        .task(id: choice) {
            guard !model.hasStarted else { return }
            if model.needsChoice {
                guard let choice else { return }
                await model.run(choice: choice)
            } else {
                await model.run()
            }
        }
        .onChange(of: model.shareFile) { _, file in
            showsShareSheet = file != nil
        }
        .sheet(isPresented: $showsShareSheet, onDismiss: {
            model.finishSharing()
            dismiss()
        }) {
            if let file = model.shareFile {
                ActivityView(items: [file])
            }
        }
        .onDisappear { model.finishSharing() }
        .sensoryFeedback(.success, trigger: succeeded)
    }

    // MARK: RAW or JPEG

    private var rawChoice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.action == .save ? "Save RAWs as:" : "Share the RAW as:")
                .font(.headline)
            Button { choice = .jpeg } label: {
                choiceLabel("JPEG", "The full-size picture, dated when it was taken.")
            }
            Button { choice = .raw } label: {
                choiceLabel("RAW", rawDetail)
            }
            if model.photos.contains(where: { !$0.raw }) {
                Text("Photos that are not RAW are saved as they are.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var rawDetail: String {
        let bytes = model.photos.filter(\.raw).compactMap(\.bytes).reduce(0, +)
        let size = GalleryFormat.megabytes(bytes)
        return (size.isEmpty ? "" : "The original file, \(size). ") + "Saves only the RAW, not a JPEG."
    }

    private func choiceLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Progress

    @ViewBuilder
    private var progress: some View {
        if model.permissionDenied {
            Text(model.message)
            if let url = SystemSettings.appURL {
                Button("Open Settings") { openURL(url) }
                    .buttonStyle(.borderedProminent)
            }
        } else if model.action == .save {
            ProgressView(value: model.progress.fraction)
            Text(model.progress.summary)
            if isFinished, !model.progress.failed.isEmpty {
                Text("Some photos could not be saved. Try again in a moment.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if model.isRunning || !model.hasStarted {
            ProgressView()
            Text("Preparing the picture…")
        } else {
            Text(model.message)
        }
    }
}
