import SwiftUI

/// Quota at the foot of the sidebar: three lines expanded, three pies collapsed.
///
/// One provider looks the way it always did. Two or more get a name above
/// each group so a Claude five-hour and a Grok five-hour cannot be mistaken
/// for each other. Staleness is per provider: a quiet Grok cache must not
/// dim Claude's numbers.
struct UsageFooter: View {
    let groups: [Usage.Group]
    let collapsed: Bool

    var body: some View {
        guard !groups.isEmpty else { return AnyView(EmptyView()) }

        let named = groups.count > 1
        return AnyView(
            VStack(alignment: collapsed ? .center : .leading, spacing: collapsed ? 8 : 5) {
                Divider().padding(.bottom, 2)
                ForEach(groups) { group in
                    if named, !collapsed {
                        Text(group.provider.name)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.top, group.id == groups.first?.id ? 0 : 4)
                    }
                    ForEach(group.meters) { meter in
                        if collapsed {
                            UsagePie(meter: meter)
                                .frame(width: 22, height: 22)
                                .help(help(group, meter))
                                .opacity(group.isStale ? 0.4 : 1)
                        } else {
                            UsageLine(meter: meter)
                                .opacity(group.isStale ? 0.4 : 1)
                                .help(group.isStale ? staleHelp(group) : "")
                        }
                    }
                }
            }
            .padding(.horizontal, collapsed ? 4 : 8)
            .padding(.bottom, 8)
        )
    }

    private func help(_ group: Usage.Group, _ meter: UsageMeter) -> String {
        let reading = "\(meter.label) \(Int(meter.percent.rounded()))%"
        let named = groups.count > 1 ? "\(group.provider.name) \(reading)" : reading
        return group.isStale ? "\(named) — \(staleHelp(group))" : named
    }

    private func staleHelp(_ group: Usage.Group) -> String {
        "No \(group.provider.name) session has refreshed usage recently"
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
