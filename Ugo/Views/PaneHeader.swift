import SwiftUI

/// The 52pt strip at the top of every pane. It stays empty apart from pane
/// controls, and leaves room for the window's traffic lights when the pane
/// is the leftmost one.
struct PaneHeader<Leading: View, Trailing: View>: View {
    var title: String? = nil
    var trafficLightInset = false
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            leading()
            if let title {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .frame(height: 52)
        .padding(.leading, trafficLightInset ? 84 : 18)
        .padding(.trailing, 12)
    }
}

extension PaneHeader where Leading == EmptyView {
    init(title: String? = nil, trafficLightInset: Bool = false, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: title, trafficLightInset: trafficLightInset, leading: { EmptyView() }, trailing: trailing)
    }
}

struct PaneButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
