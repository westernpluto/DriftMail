import SwiftUI

/// A small "new mail" toast shown while DriftMail is open.
///
/// It is a custom component, so it uses the iPhone Duo reserved-region APIs itself:
/// it moves below any camera occlusion and, when the inner display is partially
/// folded, stays inside one half instead of sitting on the fold.
struct NewMailToast: View {
    @Environment(MailStore.self) private var store
    @Environment(\.toolbarVerticalEdge) private var toolbarVerticalEdge

    var body: some View {
        GeometryReader { proxy in
            if let banner = store.banner {
                let area = targetArea(in: proxy)
                toast(banner)
                    .frame(maxWidth: min(area.width - 24, 440))
                    .position(x: area.midX, y: area.minY + 40)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: banner.id) {
                        try? await Task.sleep(for: .seconds(5))
                        withAnimation(.smooth) {
                            if store.banner?.id == banner.id { store.banner = nil }
                        }
                    }
            }
        }
    }

    private func toast(_ banner: NewMailBanner) -> some View {
        Button {
            store.reveal(banner.messageID)
            withAnimation(.smooth) { store.banner = nil }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "envelope.badge.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.drift)
                VStack(alignment: .leading, spacing: 2) {
                    Text(banner.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(banner.subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("New mail from \(banner.title): \(banner.subtitle)")
    }

    /// The rectangle the toast should be centred in.
    private func targetArea(in proxy: GeometryProxy) -> CGRect {
        var area = CGRect(origin: .zero, size: proxy.size)

        // When the display is folded, use one side of the fold.
        if let fold = proxy.reservedRegions(kind: .division).first {
            let f = fold.frame
            if f.height > f.width {
                // Vertical fold: prefer the side away from the vertical toolbar.
                let leading = CGRect(x: 0, y: 0, width: f.minX, height: proxy.size.height)
                let trailing = CGRect(x: f.maxX, y: 0, width: proxy.size.width - f.maxX, height: proxy.size.height)
                area = toolbarVerticalEdge == .trailing ? leading : trailing
            } else {
                // Horizontal fold (device held like a laptop): use the top half.
                area = CGRect(x: 0, y: 0, width: proxy.size.width, height: f.minY)
            }
        }

        // Drop below anything occluding the top band, such as the front camera.
        let band = CGRect(x: area.minX, y: area.minY, width: area.width, height: 88)
        let occludedBottom = proxy.reservedRegions(kind: .occlusion)
            .map(\.frame)
            .filter { $0.intersects(band) }
            .map(\.maxY)
            .max()
        if let occludedBottom {
            area.origin.y = max(area.origin.y, occludedBottom)
        }
        return area
    }
}
