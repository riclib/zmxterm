import SwiftUI

/// Quota at the foot of the sidebar: three lines expanded, three pies collapsed.
struct UsageFooter: View {
    let meters: [UsageMeter]
    let collapsed: Bool
    let isStale: Bool

    var body: some View {
        guard !meters.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: collapsed ? .center : .leading, spacing: collapsed ? 8 : 5) {
                Divider().padding(.bottom, 2)
                ForEach(meters) { meter in
                    if collapsed {
                        UsagePie(meter: meter)
                            .frame(width: 22, height: 22)
                            .help("\(meter.label) \(Int(meter.percent.rounded()))%")
                    } else {
                        UsageLine(meter: meter)
                    }
                }
            }
            .padding(.horizontal, collapsed ? 4 : 8)
            .padding(.bottom, 8)
            // A cache nobody is refreshing is old news, not current news.
            .opacity(isStale ? 0.4 : 1)
            .help(isStale ? "No Claude session has refreshed usage recently" : "")
        )
    }
}

private struct UsageLine: View {
    let meter: UsageMeter

    var body: some View {
        HStack(spacing: 6) {
            Text(meter.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            DotBar(percent: meter.percent, color: meter.color)
            Text("\(Int(meter.percent.rounded()))%")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(meter.color)
            if let reset = meter.reset {
                Text(reset)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The five filled/hollow dots the terminal statusline draws, kept so the thing
/// in the chrome reads as the thing it replaced.
private struct DotBar: View {
    let percent: Double
    let color: Color
    private let width = 5

    var body: some View {
        let filled = Int((percent / 100 * Double(width)).rounded(.down))
        HStack(spacing: 2) {
            ForEach(0 ..< width, id: \.self) { index in
                Circle()
                    .strokeBorder(color, lineWidth: 1.2)
                    .background(Circle().fill(index < filled ? color : .clear))
                    .frame(width: 7, height: 7)
            }
        }
    }
}

/// Collapsed, there's no room for a label or a number, so the whole reading has
/// to be the shape: a wedge from twelve o'clock, in the same colour the line
/// would have used.
private struct UsagePie: View {
    let meter: UsageMeter

    var body: some View {
        ZStack {
            Circle().strokeBorder(meter.color.opacity(0.35), lineWidth: 1)
            PieWedge(fraction: min(max(meter.percent / 100, 0), 1))
                .fill(meter.color)
                .padding(1.5)
        }
    }
}

private struct PieWedge: Shape {
    let fraction: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard fraction > 0 else { return path }
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.move(to: centre)
        path.addArc(
            center: centre,
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * fraction),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
