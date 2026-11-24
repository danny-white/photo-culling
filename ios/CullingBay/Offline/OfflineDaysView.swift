import CullingBayCore
import SwiftUI

/// Which days the phone keeps: the ones the app picked (partly culled days first, then the newest
/// untouched ones, within the size limit) and every other day, each with a menu to pin it
/// Always keep or Never, or leave it to the app (Auto).
struct OfflineDaysView: View {
    @Environment(AppServices.self) private var services

    private var offline: OfflineManager { services.offline }

    var body: some View {
        let kept = offline.plan.kept
        let keptIDs = Set(kept.map(\.id))
        let others = offline.days.filter { !keptIDs.contains($0.day) }
        List {
            Section {
                if kept.isEmpty {
                    Text(offline.days.isEmpty ? "No days yet." : "No day is picked.")
                        .foregroundStyle(.secondary)
                }
                ForEach(kept) { entry in
                    keptRow(entry)
                }
            } header: {
                Text("On this phone")
            } footer: {
                Text("Days you have started come first, then the newest you have not. Pin a day to choose for yourself.")
            }
            if !others.isEmpty {
                Section("Other days") {
                    ForEach(others) { day in
                        otherRow(day)
                    }
                }
            }
        }
        .navigationTitle("Choose days")
        .navigationBarTitleDisplayMode(.inline)
        .task { await offline.reload() }
    }

    // MARK: Rows

    private func keptRow(_ entry: OfflinePlan.Entry) -> some View {
        let day = entry.day
        let isSaved = offline.savedDays.contains(day.day)
        let size = OfflineFormat.size(entry.estimatedBytes)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title(day)).font(.body.weight(.semibold))
                Text("\(reasonText(entry.reason)) · " + (isSaved ? size : "about \(size)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            progress(day: day, isSaved: isSaved)
            pinMenu(day)
        }
        .accessibilityElement(children: .combine)
    }

    private func otherRow(_ day: Day) -> some View {
        let pin = offline.pins[day.day] ?? .auto
        var parts = ["\(day.frames) frames"]
        if pin == .never {
            parts.append("Never")
        } else if let entry = offline.plan.entry(for: day.day), !entry.fits {
            if pin == .always { parts.append("Always keep") }
            parts.append("Doesn't fit in \(OfflineFormat.size(offline.plan.limitBytes))")
        }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title(day)).font(.body)
                Text(parts.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            pinMenu(day)
        }
        .accessibilityElement(children: .combine)
    }

    /// A tick once the day is saved, a bar while it is being fetched, else a word.
    @ViewBuilder
    private func progress(day: Day, isSaved: Bool) -> some View {
        if isSaved {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Saved")
        } else if offline.syncingDay == day.day, case .syncing(_, let done, let total) = offline.state {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .frame(width: 56)
                .accessibilityLabel("Saving, \(done) of \(total)")
        } else {
            Text("Waiting").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func pinMenu(_ day: Day) -> some View {
        let pin = Binding<OfflinePin>(
            get: { offline.pins[day.day] ?? .auto },
            set: { offline.pin(day.day, $0) })
        return Menu {
            Picker("Keep this day", selection: pin) {
                Text("Auto").tag(OfflinePin.auto)
                Text("Always keep").tag(OfflinePin.always)
                Text("Never").tag(OfflinePin.never)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: pin.wrappedValue == .auto ? "ellipsis.circle" : "pin.circle.fill")
                .font(.title3)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Keep options for \(title(day))")
        .accessibilityValue(pinWord(pin.wrappedValue))
    }

    // MARK: Words

    private func title(_ day: Day) -> String {
        CullFormat.dayTitle(date: day.date, folder: day.folder)
    }

    private func reasonText(_ reason: OfflinePlan.Reason) -> String {
        switch reason {
        case .always: "Always kept"
        case .inProgress: "In progress"
        case .newest: "Newest"
        }
    }

    private func pinWord(_ pin: OfflinePin) -> String {
        switch pin {
        case .auto: "Auto"
        case .always: "Always keep"
        case .never: "Never"
        }
    }
}
