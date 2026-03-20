import SwiftUI

// MARK: - ThumbnailCell

struct ThumbnailCell: View {
    let item: MediaItem
    let isSelected: Bool

    @State private var thumbnail: NSImage? = nil
    @State private var isHovered = false

    private let size: CGFloat = 160

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Thumbnail image or placeholder
            Group {
                if let img = thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: item.mediaType.systemImage)
                                .font(.system(size: 28))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Bottom overlay: duration badge
            if let dur = item.formattedDuration {
                Text(dur)
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }

            // Top-right: favorite badge
            if item.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.pink)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            // Video play icon on hover
            if item.mediaType == .video && isHovered {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isSelected ? Color.accentColor : Color.clear,
                    lineWidth: isSelected ? 2.5 : 0
                )
        }
        .scaleEffect(isSelected ? 0.96 : 1.0)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
        .onHover { isHovered = $0 }
        .task(id: item.thumbnailCacheKey) {
            thumbnail = await ThumbnailService.shared.thumbnailAsync(for: item)
        }
    }
}
