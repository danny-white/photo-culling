import CullingBayCore
import SwiftUI
import UIKit

/// The burst picker (`vStrip` in `app.js`): any burst as a filmstrip, the big frame above and
/// a strip below that scrolls through every frame and keeps the one on show in the middle. The
/// state is `CullPickerModel`; this draws it and maps gestures onto it. Keeping goes through the
/// session, as any decision does.
struct CullPickerView: View {
    @Environment(AppServices.self) private var services
    let session: CullSessionModel

    var body: some View {
        if let picker = session.picker {
            VStack(spacing: 0) {
                CullDayHeader(
                    title: picker.title, backTitle: "Cancel", backIcon: nil, onBack: { session.closePicker() }
                ) {
                    Text(picker.subtitle)
                }
                CullOfflineBanner(queue: session.queue)
                CullStripPicker(session: session, picker: picker)
                footer(picker)
            }
        }
    }

    private func footer(_ picker: CullPickerModel) -> some View {
        VStack(spacing: 8) {
            Text(picker.note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(picker.rejectAllLabel) { session.reject() }
                    .buttonStyle(CullFooterStyle(isPrimary: false))
                Button(picker.keepLabel) { session.keepPicked() }
                    .buttonStyle(CullFooterStyle(isPrimary: true))
                    .disabled(!picker.canKeep)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
        // The labels grow with the text size, but not so far that the row breaks.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

// MARK: Filmstrip

/// The big frame to swipe through, the thumbnails with their ticks, and the star row.
private struct CullStripPicker: View {
    @Environment(AppServices.self) private var services
    let session: CullSessionModel
    let picker: CullPickerModel

    var body: some View {
        VStack(spacing: 0) {
            CullStripMain(session: session, picker: picker)
            thumbnails
            stars
        }
        .task(id: picker.viewIndex) { await prefetchNeighbours() }
    }

    // MARK: Thumbnails

    private var thumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(picker.frames) { item in
                        thumbnail(item).id(item.index)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 18)
            }
            .onChange(of: picker.viewIndex) { _, index in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(index, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(picker.viewIndex, anchor: .center) }
        }
        .frame(height: 76)
    }

    private func thumbnail(_ item: CullPickerFrame) -> some View {
        let isCurrent = item.index == picker.viewIndex
        let ticked = picker.isTicked(item.id)
        // A decision on this frame that the PC does not have yet.
        let onlyOnPhone = session.queue.isPending(frameID: item.id)
        return Button { picker.show(item.index) } label: {
            RemoteImage(url: services.client.imageURL(id: item.id, size: .thumb), fit: true)
                .frame(width: 62, height: 42)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(2)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isCurrent ? Color.white : Color.clear, lineWidth: 2)
                }
                .overlay(alignment: .topTrailing) {
                    if ticked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(Color.black)
                            .frame(width: 18, height: 18)
                            .background(Color.green, in: Circle())
                            .offset(x: 6, y: -6)
                    }
                }
                .overlay(alignment: .bottom) {
                    if item.isSharpest {
                        Circle().fill(Color.yellow).frame(width: 5, height: 5).offset(y: 10)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if onlyOnPhone {
                        Image(systemName: "iphone")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.orange)
                            .shadow(color: .black, radius: 1)
                            .padding(5)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.frame.file + (item.isSharpest ? ", the sharpest" : ""))
        .accessibilityValue(
            [ticked ? "Kept" : nil, onlyOnPhone ? "on this phone, not saved to the PC yet" : nil]
                .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    // MARK: Stars

    /// Rates the frame on the big picture, and ticks it.
    private var stars: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { stars in
                Button { picker.rate(stars: stars) } label: {
                    Image(systemName: "star.fill")
                        .font(.body)
                        .foregroundStyle(stars <= picker.viewedStars ? Color.yellow : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(CullStyle.panel, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(stars == 1 ? "1 star" : "\(stars) stars")
                .accessibilityHint("Rates this frame and keeps it")
                .accessibilityAddTraits(stars <= picker.viewedStars ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rate this frame")
    }

    // MARK: Prefetch

    /// The pictures either side of the one on show, decoded, so a swipe lands on a sharp frame.
    private func prefetchNeighbours() async {
        do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
        let client = services.client, loader = services.loader
        for index in [picker.viewIndex + 1, picker.viewIndex - 1] where picker.frames.indices.contains(index) {
            let url = client.imageURL(id: picker.frames[index].id, size: .view)
            _ = await ImagePipeline.load(url, maxPixel: ImagePixels.view, loader: loader)
        }
    }
}

/// The big frame of the filmstrip: swipe sideways to look at the next, double-tap to check its
/// focus, the tick at the corner to keep it.
private struct CullStripMain: View {
    @Environment(AppServices.self) private var services
    let session: CullSessionModel
    let picker: CullPickerModel

    var body: some View {
        let item = picker.viewed
        ZStack {
            Color.black
            // A new page for each frame, so the one before is never seen under the next one's marks.
            CullStripPhoto(
                session: session, picker: picker, frame: item.frame,
                viewURL: services.client.imageURL(id: item.id, size: .view),
                thumbURL: services.client.imageURL(id: item.id, size: .thumb)
            ).id(item.id)
            overlays(item)
        }
        .clipped()
    }

    private func overlays(_ item: CullPickerFrame) -> some View {
        ZStack {
            VStack(alignment: .leading, spacing: 4) {
                CullBadgesView(badges: item.badges)
                Spacer(minLength: 0)
                Text(CullFormat.stem(item.frame.file) + " · \(item.index + 1)/\(picker.frames.count)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
            .allowsHitTesting(false)
            if let mark = item.mark {
                CullMarkPill(mark: mark)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(8)
                    .allowsHitTesting(false)
            }
            tick(item)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(12)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func tick(_ item: CullPickerFrame) -> some View {
        let on = picker.isTicked(item.id)
        return Button { picker.tick() } label: {
            Image(systemName: "checkmark")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(on ? Color.black : Color.clear)
                .frame(width: 46, height: 46)
                .background(on ? Color.green : Color.black.opacity(0.35), in: Circle())
                .overlay(Circle().strokeBorder(on ? Color.green : Color.white, lineWidth: 2))
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Keep \(item.frame.file)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// One frame's picture in the filmstrip, with the gestures on it.
private struct CullStripPhoto: View {
    @Environment(AppServices.self) private var services
    let session: CullSessionModel
    let picker: CullPickerModel
    let frame: Frame
    let viewURL: URL
    let thumbURL: URL
    @State private var image: UIImage?
    @State private var loadFailed = false

    init(session: CullSessionModel, picker: CullPickerModel, frame: Frame, viewURL: URL, thumbURL: URL) {
        self.session = session
        self.picker = picker
        self.frame = frame
        self.viewURL = viewURL
        self.thumbURL = thumbURL
        // Swiping to a frame prefetched is sharp in the first frame it is on screen.
        _image = State(
            initialValue: DecodedImageCache.shared.image(for: viewURL, maxPixel: ImagePixels.view)
                ?? DecodedImageCache.shared.image(for: thumbURL, maxPixel: ImagePixels.thumb))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .overlay {
                            if let af = frame.afPoint { CullAFBoxView(point: af) }
                        }
                } else if loadFailed {
                    Text("Couldn’t load this photo.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    session.openFocus(tapped: tapped(value.location, in: geometry.size))
                }
            )
            .simultaneousGesture(swipe)
        }
        .task { await load() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(frame.file + ", \(picker.viewIndex + 1) of \(picker.frames.count)")
        .accessibilityHint("Double-tap to check focus")
        .accessibilityAddTraits(.isImage)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: picker.step(1)
            case .decrement: picker.step(-1)
            @unknown default: break
            }
        }
    }

    /// A sideways swipe of 50 pt or more looks at the next frame (left) or the one before (right).
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > 50, abs(dx) > abs(dy) else { return }
                picker.step(dx < 0 ? 1 : -1)
            }
    }

    /// Where a double-tap fell on the photo, as fractions of it.
    private func tapped(_ location: CGPoint, in area: CGSize) -> Point {
        let ratio = image.map { $0.size.width / max($0.size.height, 1) } ?? 1.5
        let width = min(area.width, area.height * ratio)
        let height = width / ratio
        return CullFocusModel.imagePoint(
            x: Double(location.x), y: Double(location.y),
            in: Rect(
                x: Double((area.width - width) / 2), y: Double((area.height - height) / 2),
                width: Double(width), height: Double(height)))
    }

    // MARK: Loading

    /// The thumbnail first, which is on the strip already, then the 1616 px picture.
    private func load() async {
        if DecodedImageCache.shared.image(for: viewURL, maxPixel: ImagePixels.view) != nil { return }
        if image == nil,
           let thumb = await ImagePipeline.load(thumbURL, maxPixel: ImagePixels.thumb, loader: services.loader),
           !Task.isCancelled, image == nil {
            image = thumb.image
        }
        if let full = await ImagePipeline.load(viewURL, maxPixel: ImagePixels.view, loader: services.loader),
           !Task.isCancelled {
            image = full.image
        } else if !Task.isCancelled && image == nil {
            loadFailed = true
        }
    }
}

/// A frame's mark as a pill: `Kept ★★★`, `Hero`, `Rejected`, `Picked in Lightroom`.
struct CullMarkPill: View {
    let mark: FrameMark

    var body: some View {
        Text(mark.text + (mark.stars > 0 ? " " + CullFormat.starText(mark.stars) : ""))
            .font(.caption2.weight(.bold))
            .foregroundStyle(mark.verdict == .reject ? Color.white : Color.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(CullStyle.color(mark.verdict), in: Capsule())
    }
}
