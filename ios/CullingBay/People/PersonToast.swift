import SwiftUI

/// A line at the foot of the person's screen: what "Not Alex" on a photo did, with Undo when it can be
/// taken back. It is made like the Cull tab's toast (`CullToastView`), which is tied to a Cull
/// session and so can't be used here. The Cull tab is always dark, so its toast has white text on gray;
/// this screen follows the light or dark setting, so the text and the background are the system's.
struct PersonToast: Identifiable {
    /// 1, 2, ...: tells one toast from the next, even with the same text.
    let id: Int
    let text: String
    /// Nil for a toast with nothing to undo.
    let undo: (() -> Void)?
}

/// Shows a `PersonToast`. It goes after about 4 s, or on a tap; one with Undo stays while VoiceOver is
/// running, because reaching the button takes longer than a tap does.
struct PersonToastView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverRunning
    let toast: PersonToast?
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            if let toast {
                HStack(spacing: 12) {
                    Text(toast.text)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let undo = toast.undo {
                        Button("Undo") {
                            dismiss()
                            undo()
                        }
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .frame(minHeight: 44)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .frame(minHeight: 44)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                .contentShape(RoundedRectangle(cornerRadius: 14))
                .onTapGesture { dismiss() }
                .id(toast.id)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
                .task(id: toast.id) {
                    // A newer toast restarts this task, so each one gets its own 4 s.
                    if toast.undo != nil && voiceOverRunning { return }
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }
                    dismiss()
                }
                .onAppear { AccessibilityNotification.Announcement(toast.text).post() }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: toast?.id)
    }
}
