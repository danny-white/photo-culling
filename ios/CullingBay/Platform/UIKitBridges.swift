import SwiftUI
import UIKit

/// The system share sheet.
struct ActivityView: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

@MainActor
enum SystemSettings {
    /// This app's page in the Settings app, where Photos access can be changed.
    static var appURL: URL? {
        URL(string: UIApplication.openSettingsURLString)
    }
}
