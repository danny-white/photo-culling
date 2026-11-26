import CullingBayCore
import SwiftUI

/// A face's picture in a circle, as big as the space it is given (it keeps to a square). It loads
/// through the same `RemoteImage` as the photo tiles, so the pictures share the loader's
/// requests and the decoded cache. No face (a person with none left) is a plain grey circle.
struct FaceCircle: View {
    @Environment(AppServices.self) private var services
    let face: Int?
    /// `small` is 160 px, enough for a circle up to about 80 pt; `large` is 480 px.
    var size: FaceSize = .small

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let face {
                    RemoteImage(
                        url: services.client.faceURL(id: face, size: size),
                        maxPixel: size == .small ? ImagePixels.face : ImagePixels.faceLarge)
                } else {
                    Color(.secondarySystemFill)
                        .overlay { Image(systemName: "person.fill").foregroundStyle(.secondary) }
                }
            }
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}
