import CullingBayCore
import SwiftUI

/// One square thumbnail in a results grid, with its date (when the results span days) and
/// stars, and a tick while it is selected.
struct PhotoTile: View {
    @Environment(AppServices.self) private var services
    let photo: Photo
    let showsDate: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let onLoad: (() -> Void)?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                RemoteImage(url: services.client.imageURL(id: photo.id, size: .thumb), onLoad: onLoad)
            }
            .overlay(alignment: .bottomLeading) {
                let date = GalleryFormat.shortDate(photo.date)
                if showsDate, !date.isEmpty {
                    Text(date)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2, y: 1)
                        .padding(.leading, 5)
                        .padding(.bottom, 4)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if photo.stars > 0 {
                    Text(GalleryFormat.stars(photo.stars))
                        .font(.caption2)
                        .foregroundStyle(Color.yellow)
                        .shadow(color: .black, radius: 2, y: 1)
                        .padding(.trailing, 5)
                        .padding(.bottom, 4)
                }
            }
            .overlay {
                if isSelected {
                    ZStack {
                        Color.black.opacity(0.35)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white, Color.accentColor)
                    }
                } else if isSelecting {
                    Image(systemName: "circle")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibilityText: String {
        [
            "Photo",
            GalleryFormat.longDate(photo.date),
            photo.stars > 0 ? "\(photo.stars) stars" : "",
        ].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
