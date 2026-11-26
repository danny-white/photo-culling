import CullingBayCore
import SwiftUI

/// Work offline is on: a small orange capsule with an aeroplane, the phone's own sign for Airplane
/// Mode, and Go online, which turns it off. It sits at the top of each tab's first screen and of an
/// opened day, and shows nothing while Work offline is off. On a day's screens it also says how
/// many taps are waiting to save.
struct WorkingOfflineBar: View {
    @Environment(AppServices.self) private var services
    /// Taps waiting on the phone; 0 leaves the count out.
    var waiting = 0

    var body: some View {
        if services.link.isWorkingOffline {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "airplane")
                    Text(waiting > 0 ? "Working offline · \(waiting) waiting to save" : "Working offline")
                }
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(Color.black)
                .background(Color.orange, in: Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Working offline")
                .accessibilityValue(waiting > 0 ? "\(waiting) waiting to save" : "")
                Button("Go online") { services.link.setWorkingOffline(false) }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint("Turns off Work offline")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
    }
}

/// The PC cannot be reached: a quiet yellow line, with Try now, which probes at once. The app
/// probes by itself too, more slowly the longer the PC stays away.
struct UnreachableBanner: View {
    @Environment(AppServices.self) private var services
    /// Whether days are kept on the phone, so saved days open without the PC.
    let hasSavedDays: Bool
    @State private var trying = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "wifi.slash")
                Text(hasSavedDays ? "Can't reach the PC · saved days open from this phone" : "Can't reach the PC")
                    .multilineTextAlignment(.leading)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.yellow)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Offline: can't reach the PC")
            .accessibilityValue(hasSavedDays ? "Saved days open from this phone" : "")
            Button {
                trying = true
                Task {
                    await services.link.checkNow()
                    trying = false
                }
            } label: {
                Text("Try now").opacity(trying ? 0 : 1)
                    .overlay { if trying { ProgressView().controlSize(.small) } }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(trying)
            .accessibilityLabel("Try now")
            .accessibilityHint("Checks whether the PC can be reached")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}
