import AppKit
import SwiftUI

/// For the README: the panel hanging from fwd's icon in a menu bar, drawn
/// by `--snapshot-hero`. The bar's other items are stand-ins; the icon and
/// the panel are the app's own.
struct HeroSnapshot<Panel: View>: View {
    let panel: Panel

    private let width: CGFloat = 640
    private let barHeight: CGFloat = 26
    /// Where fwd's icon sits in the bar, and the panel's left edge under it.
    private let iconX: CGFloat = 150
    private let panelX: CGFloat = 112

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.36, green: 0.55, blue: 0.85), Color(red: 0.55, green: 0.42, blue: 0.78)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            menuBar

            panel
                .frame(width: 440)
                .background(.windowBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
                .padding(.top, barHeight + 6)
                .padding(.leading, panelX)
                .padding(.bottom, 28)
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var menuBar: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(.bar).frame(height: barHeight)
            Image(nsImage: FwdMark.menuBarImage(.forwarding))
                .padding(.horizontal, 6).padding(.vertical, 2)
                // How the bar marks the item whose menu is open.
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.14)))
                .offset(x: iconX - 6)
            HStack(spacing: 16) {
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Image(systemName: "magnifyingglass")
                Text(verbatim: "Thu 9:41")
            }
            .font(.system(size: 13, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 14)
        }
        .frame(width: width, height: barHeight)
    }
}
