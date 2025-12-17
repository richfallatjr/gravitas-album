import SwiftUI

struct AlbumCurvedLayoutTileView: View {
    let item: AlbumCurvedLayoutItem
    let isSelected: Bool
    let thumbnailView: AnyView

    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        ZStack {
            thumbnailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .center,
                endPoint: .bottom
            )
            .opacity((item.title?.isEmpty == false || item.subtitle?.isEmpty == false) ? 1 : 0)

            if isSelected {
                shape.strokeBorder(Color.accentColor, lineWidth: 2)
            } else {
                shape.strokeBorder(.white.opacity(0.08), lineWidth: 1)
            }
        }
        .overlay(alignment: .topLeading) {
            badge
        }
        .overlay(alignment: .bottomLeading) {
            titleStack
        }
        .background(shape.fill(.black.opacity(0.06)))
        .clipShape(shape)
    }

    @ViewBuilder
    private var badge: some View {
        if item.isVideo {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.caption2.weight(.semibold))
                if let duration = item.duration {
                    Text(formatDuration(duration))
                        .font(.caption2.monospacedDigit())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .padding(10)
        }
    }

    @ViewBuilder
    private var titleStack: some View {
        if item.title?.isEmpty == false || item.subtitle?.isEmpty == false {
            VStack(alignment: .leading, spacing: 3) {
                if let title = item.title, !title.isEmpty {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .padding(10)
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        let m = total / 60
        let s = total % 60
        if m > 0 { return String(format: "%dm%02ds", m, s) }
        return "\(s)s"
    }
}

