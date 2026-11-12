import SwiftUI

/// The line to a machine is down: shown over the chat and over the terminal, so a dead line never
/// looks live. Colors come from the caller (the chat's palette, or the terminal theme's).
struct ConnectionBar: View {
    let session: HostSession
    let text: Color
    let secondary: Color
    let background: Color
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if case .failed(_, retrying: false) = session.state {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(session.state, machine: session.host.name))
                    .font(.footnote.weight(.semibold)).foregroundStyle(text)
                if let heard = session.lastHeardAt {
                    // Ticks by itself: "last update 2 min ago" stays true while the line is down.
                    TimelineView(.periodic(from: .now, by: 15)) { _ in
                        Text("Last update \(heard, format: .relative(presentation: .named))")
                            .font(.caption).foregroundStyle(secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            if case .failed(_, retrying: false) = session.state {
                Button("Retry", action: retry).font(.footnote.weight(.semibold))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(background)
        .accessibilityElement(children: .combine)
    }

    static func title(_ state: HostSession.State, machine: String) -> String {
        switch state {
        case .connected: "Connected"
        case .idle: "Not connected to \(machine)"
        case .connecting: "Reconnecting to \(machine)…"
        case .failed(let why, retrying: true): "Reconnecting to \(machine)… (\(why))"
        case .failed(let why, retrying: false): why
        }
    }
}
