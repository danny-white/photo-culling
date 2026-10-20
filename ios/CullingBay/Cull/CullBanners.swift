import CullingBayCore
import SwiftUI
import UIKit

/// `Offline · 3 waiting to save`, while the queue cannot reach the server. The taps are safe:
/// they are kept on the phone and go out when the server answers again.
struct CullOfflineBanner: View {
    let queue: CullWriteQueue

    var body: some View {
        if queue.isOffline {
            Text("Offline · \(queue.pending) waiting to save")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.yellow)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

/// What the day just did (`Rejected DSC05050 · Undo`). It goes after about 4 s, or on a tap.
struct CullToastView: View {
    private static let lifetime: Duration = .seconds(4)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: CullSessionModel

    var body: some View {
        ZStack {
            if let toast = session.toast {
                HStack(spacing: 12) {
                    Text(toast.text)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if toast.offersUndo {
                        Button("Undo") { session.undo() }
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                            .frame(minHeight: 44)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .frame(minHeight: 44)
                .background(Color(.systemGray5).opacity(0.97), in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
                .onTapGesture { session.dismissToast() }
                .id(toast.id)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
                .task(id: toast.id) {
                    // A newer toast restarts this task, so each one gets its own 4 s.
                    do { try await Task.sleep(for: Self.lifetime) } catch { return }
                    session.dismissToast()
                }
                .onAppear { AccessibilityNotification.Announcement(toast.text).post() }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: session.toast?.id)
    }
}
