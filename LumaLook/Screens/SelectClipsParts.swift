import SwiftUI
import Photos

// MARK: - Thumbnail

/// A library asset's thumbnail (or a bundled sample in DEBUG), filling
/// whatever frame it's given. Loads on appear, cancels on disappear.
struct RollThumbnail: View {
    let tile: RollTile
    let pixelSide: CGFloat
    let manager: PHCachingImageManager?
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        Color.clear
            .overlay { picture.allowsHitTesting(false) }
            .clipped()
            .contentShape(Rectangle())
            .onAppear(perform: load)
            .onDisappear(perform: cancel)
    }

    @ViewBuilder private var picture: some View {
        if let sample = tile.sample {
            HeroImage(photo: sample)
        } else if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            LumaTheme.raised
        }
    }

    private func load() {
        guard image == nil, requestID == nil, let asset = tile.asset, let manager else { return }
        requestID = RollThumbnails.request(asset, pixelSide: pixelSide, manager: manager) { loaded in
            image = loaded
        }
    }

    private func cancel() {
        if let requestID, let manager {
            manager.cancelImageRequest(requestID)
        }
        requestID = nil
    }
}

// MARK: - Grid cell

/// One square in the grid: thumbnail, pick badge (numbered in signal yellow
/// when picked, an empty ring when not) and the duration for videos.
struct RollGridCell: View {
    let tile: RollTile
    /// 1-based pick order, nil when not picked.
    let number: Int?
    let pixelSide: CGFloat
    let manager: PHCachingImageManager?
    let action: () -> Void

    private var isPicked: Bool { number != nil }

    var body: some View {
        Button(action: action) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    RollThumbnail(tile: tile, pixelSide: pixelSide, manager: manager)
                        .opacity(isPicked ? 0.78 : 1)
                }
                .overlay { pickedRim }
                .overlay(alignment: .topTrailing) { badge.padding(7) }
                .overlay(alignment: .bottomTrailing) { durationLabel }
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(spokenLabel))
        .accessibilityValue(Text(spokenValue))
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    private var spokenLabel: String {
        if tile.isVideo {
            return "Video, " + RollClock.string(tile.duration)
        }
        return "Photo"
    }

    private var spokenValue: String {
        guard let number else { return "" }
        return "Picked, number \(number)"
    }

    @ViewBuilder private var pickedRim: some View {
        if isPicked {
            Rectangle()
                .strokeBorder(LumaTheme.signal, lineWidth: 2)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var badge: some View {
        if let number {
            Text("\(number)")
                .font(.luma(size: 12, weight: .bold))
                .foregroundStyle(LumaTheme.onSignal)
                .frame(width: 22, height: 22)
                .background(LumaTheme.signal, in: Circle())
        } else if tile.isPickable {
            Circle()
                .fill(Color.black.opacity(0.2))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5))
                .frame(width: 22, height: 22)
        }
    }

    @ViewBuilder private var durationLabel: some View {
        if tile.isVideo {
            Text(RollClock.string(tile.duration))
                .font(.luma(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
                .padding(.trailing, 7)
                .padding(.bottom, 6)
        }
    }
}

// MARK: - Tray thumbnail

/// A pick in the tray, in pick order. Tapping it removes the pick.
struct RollPickThumb: View {
    let tile: RollTile
    let pixelSide: CGFloat
    let manager: PHCachingImageManager?

    var body: some View {
        RollThumbnail(tile: tile, pixelSide: pixelSide, manager: manager)
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(LumaTheme.edge, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(Color.black.opacity(0.6), in: Circle())
                    .padding(3)
            }
    }
}

// MARK: - States

/// Photos access is off: a calm Night Lab empty state with one way out.
struct RollDeniedView: View {
    let openSettings: () -> Void
    let notNow: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LumaTheme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(LumaTheme.edge, lineWidth: 1))
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(LumaTheme.textSecondary)
            }
            .frame(width: 76, height: 76)
            .padding(.bottom, 24)

            LumaHeadline(light: "Photos access is", heavy: "off", size: 28)
                .multilineTextAlignment(.center)
                .padding(.bottom, 10)

            Text("Allow access in Settings to pick clips and photos from your library.")
                .font(.luma(size: 15))
                .foregroundStyle(LumaTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 28)

            SolidCTA(title: "Open Settings", action: openSettings)

            Button(action: notNow) {
                Text("Not now")
                    .font(.luma(size: 15, weight: .medium))
                    .foregroundStyle(LumaTheme.textMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
            .padding(.top, 6)
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Waiting for the system's Photos prompt.
struct RollAskingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().tint(LumaTheme.textSecondary)
            Text("Waiting for Photos access")
                .font(.luma(size: 14, weight: .medium))
                .foregroundStyle(LumaTheme.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
