import CullingBayCore
import SwiftUI

/// One Send all, ready to show in a `CullSendAllView`.
struct CullSendAllLaunch: Identifiable {
    let id = UUID()
    let model: CullSendAllModel
}

/// Send to Lightroom for many days at once: the days with decisions not yet sent, the finished
/// ones ticked, untick any to leave them, then one send writes them all to the inbox for the
/// plug-in's Sync AI Cull Data on the Mac.
struct CullSendAllView: View {
    @Environment(\.dismiss) private var dismiss
    let model: CullSendAllModel
    /// The days list, refreshed once something was sent.
    let onSent: () async -> Void

    var body: some View {
        NavigationStack {
            Group {
                if model.isEmpty {
                    Text("Nothing is waiting to go to Lightroom.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if !model.finished.isEmpty {
                            Section("Finished") { rows(model.finished) }
                        }
                        if !model.unfinished.isEmpty {
                            Section {
                                rows(model.unfinished)
                            } header: {
                                Text("Not finished yet")
                            } footer: {
                                Text("Their decisions so far can go too; tick them to send.")
                            }
                        }
                    }
                    .disabled(model.isSending || model.didSend)
                }
            }
            .navigationTitle("Send to Lightroom")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.didSend ? "Done" : "Cancel") { dismiss() }
                }
                if !model.isEmpty && !model.didSend {
                    ToolbarItem(placement: .primaryAction) {
                        Button(model.selected.count == model.all.count ? "None" : "All") {
                            if model.selected.count == model.all.count { model.selectNone() } else { model.selectAll() }
                        }
                        .disabled(model.isSending)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !model.isEmpty { footer }
            }
        }
    }

    private func rows(_ items: [CullSendAllModel.Item]) -> some View {
        ForEach(items) { item in
            Button { model.toggle(item.id) } label: {
                HStack(spacing: 12) {
                    Image(systemName: model.isSelected(item.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(model.isSelected(item.id) ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.body.weight(.semibold))
                        Text([item.place, item.countText].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(model.isSelected(item.id) ? .isSelected : [])
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if !model.message.isEmpty {
                Text(model.message)
                    .font(.footnote)
                    .foregroundStyle(model.didSend ? Color.primary : Color.yellow)
                    .multilineTextAlignment(.center)
            } else if !model.selected.isEmpty {
                Text(model.selectionText).font(.footnote).foregroundStyle(.secondary)
            }
            if model.didSend {
                Button("Done") { dismiss() }
                    .buttonStyle(CullFooterStyle(isPrimary: true))
            } else {
                Button {
                    Task {
                        if await model.send() { await onSent() }
                    }
                } label: {
                    if model.isSending {
                        ProgressView().tint(.black)
                    } else {
                        Text(model.sendLabel)
                    }
                }
                .buttonStyle(CullFooterStyle(isPrimary: true))
                .disabled(model.selected.isEmpty || model.isSending)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
    }
}
