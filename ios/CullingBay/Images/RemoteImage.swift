import CullingBayCore
import SwiftUI
import UIKit

/// A picture from the photo server, filling the space it is given (crop to fit; or `fit: true`
/// to show the whole picture inside it). It loads
/// through the shared `ImageDataLoader`, decodes off the main thread, and shows a grey square
/// until it arrives. `onLoad` is called once the picture is on screen.
struct RemoteImage: View {
    @Environment(AppServices.self) private var services
    let url: URL
    let maxPixel: Int
    let fit: Bool
    let onLoad: (() -> Void)?
    @State private var image: UIImage?

    init(url: URL, maxPixel: Int = ImagePixels.thumb, fit: Bool = false, onLoad: (() -> Void)? = nil) {
        self.url = url
        self.maxPixel = maxPixel
        self.fit = fit
        self.onLoad = onLoad
        _image = State(initialValue: DecodedImageCache.shared.image(for: url, maxPixel: maxPixel))
    }

    var body: some View {
        Color(.secondarySystemFill)
            .overlay {
                if let image {
                    if fit {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                }
            }
            .clipped()
            .task(id: url) { await load() }
    }

    private func load() async {
        if image == nil {
            guard let loaded = await ImagePipeline.load(url, maxPixel: maxPixel, loader: services.loader)
            else { return }
            image = loaded.image
        }
        onLoad?()
    }
}
