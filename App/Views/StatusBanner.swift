import HerdrKit
import SwiftUI

struct StatusBanner: View {
    let item: BannerItem
    let open: () -> Void
    let dismiss: () -> Void

    private var text: String {
        let n = item.transition.name
        return item.transition.to == .blocked ? "„\(n)“ wartet auf Freigabe" : "„\(n)“ ist fertig"
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: item.transition.to.symbol).foregroundStyle(item.transition.to.color).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(item.serverName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .gesture(DragGesture(minimumDistance: 10).onEnded { if $0.translation.height < 0 { dismiss() } })
        .accessibilityHint("Öffnet den Agent")
    }
}
