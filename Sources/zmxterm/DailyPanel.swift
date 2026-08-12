import AppKit
import SwiftUI

/// Today's daily note as a stack of cards, one per top-level bullet, newest
/// first.
///
/// Nothing here follows the focused pane, which makes it the first inspector
/// panel that is about the *day* rather than about a session — the container
/// was built for a second panel and this is what it turned out to be.
///
/// It was originally twelve truncated lines with the rest behind a tooltip, and
/// both halves of that were concessions to a panel that might have lived in a
/// footer under the usage meters. It has a column. A 300-character bullet
/// clipped to one line, with the remainder only reachable by hovering, is
/// strictly worse than the same bullet laid out — so the cards wrap, and every
/// entry of the day is here.
///
/// It draws only when `Daily.settings` is set, and the panel is not offered at
/// all otherwise: see `InspectorPanel.available`. Most people have no daily note
/// and should see no panel, no placeholder, and no explanation of a feature they
/// did not ask for.
struct DailyPanel: View {
    @ObservedObject var monitor: DailyMonitor

    var body: some View {
        VStack(spacing: 0) {
            pathHeader
            Divider()
            content
        }
        // The timer covers a note appearing while the window is elsewhere, but
        // looking at the panel is the moment its content matters most, and a
        // refresh is one `stat` and a small read.
        .onAppear { monitor.refresh() }
    }

    private var pathHeader: some View {
        HStack(spacing: 6) {
            Text(monitor.relativePath.isEmpty ? "—" : monitor.relativePath)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // The tail identifies the note; the head is the folder every
                // one of them shares.
                .truncationMode(.head)
            Spacer(minLength: 0)
            if let name = monitor.settings?.adapter.name {
                Text(name)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { open() }
        .help(monitor.absolutePath ?? "")
    }

    @ViewBuilder
    private var content: some View {
        switch monitor.note {
        case .missing:
            // The normal state of every morning. Not an error, and not phrased
            // as one.
            InspectorPlaceholder(text: "Nothing written today yet")
        case .downloading:
            // Never "no work today" for a note that exists on another machine —
            // saying the day was empty when it was only absent is the worst
            // thing this panel could get wrong.
            InspectorPlaceholder(text: "Fetching today's note from iCloud…")
        case let .unreadable(reason):
            InspectorPlaceholder(text: reason)
        case .text:
            if monitor.bullets.isEmpty {
                InspectorPlaceholder(text: "No top-level entries yet")
            } else {
                entries
            }
        }
    }

    /// As long as the day was. `LazyVStack` builds only the cards on screen,
    /// which matters more here than it did at twelve: a note is appended to all
    /// day and nothing caps it.
    private var entries: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.gap) {
                ForEach(monitor.bullets) { bullet in
                    DailyCard(bullet: bullet, onOpen: open)
                }
            }
            .padding(Theme.gap)
        }
    }

    /// Clicking any line opens the *note*, not the line — neither scheme
    /// addresses a block, and a link that claims to would land somewhere else.
    ///
    /// A missing app fails quietly: `NSWorkspace.open` returns false for a
    /// scheme nobody has registered, and a dialog about it would be this app
    /// complaining about another app's absence.
    private func open() {
        guard let url = monitor.url else { return }
        if !NSWorkspace.shared.open(url) {
            Log.debug("daily: nothing opened \(url.scheme ?? "?"):// — is the app installed?")
        }
    }
}

/// One entry, whole: markdown rendered where it is free, wrapped to as many
/// lines as it takes.
///
/// The chrome is the app's own — `Theme.groupCard` on `Theme.chrome`, at
/// `Theme.cornerRadius`, spaced by `Theme.gap` — which is exactly what a tab
/// group in the left rail and a pane in the split canvas are made of. A card
/// invented here would be a widget dropped into the application; this is the
/// application.
///
/// **There is no tooltip, and that is the change.** It used to carry the text
/// the truncation hid, and with the whole line on screen it would only repeat
/// what you are already reading. What it also did, by accident, was be the one
/// thing that responded to the pointer — so the affordance it was carrying is
/// replaced deliberately and doubled: the card takes an accent border under the
/// pointer, and the cursor becomes the pointing hand, which is the strongest
/// "this opens something" signal macOS has. Which app the click opens does not go here
/// either; it is in the header, permanently, rather than in a tooltip that
/// fires once per card as you read down a day's work.
private struct DailyCard: View {
    let bullet: Daily.Bullet
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Text(bullet.rendered)
            .font(.system(size: 11))
            // No `lineLimit`: the whole point is that the line is all here.
            // `.fixedSize` vertically is what makes a `Text` in a `LazyVStack`
            // take the height its wrapping needs instead of one line's worth.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .fill(Theme.groupCard)
            )
            // The hover state, which is now the only thing saying this is a
            // click target. An overlay stroke rather than a different fill:
            // changing the fill would make the card look like a *different kind*
            // of card — the rail already uses fill to mean selected and
            // `failedCard` to mean something went wrong — where a border reads
            // as "this one, now".
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(Color.accentColor.opacity(isHovering ? 0.7 : 0), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                // push/pop rather than set, the same discipline the divider
                // handles use: the system resets the cursor on every
                // mouse-moved event, so a plain `set` flickers.
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            // A push with no pop leaves the pointing hand stuck over the whole
            // window, and unlike the divider handles these cards *do* vanish
            // from under the pointer: the list is rebuilt whenever the note
            // changes, and the note changes while somebody is reading it. So
            // the pop happens on the way out however the way out happens.
            .onDisappear {
                guard isHovering else { return }
                isHovering = false
                NSCursor.pop()
            }
            .onTapGesture(perform: onOpen)
    }
}
