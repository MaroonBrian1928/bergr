import SwiftUI

/// "While you were away": one row per agent that finished, needs you or failed.
struct DigestCard: View {
    let model: AwayDigestModel
    let open: (_ host: Host.ID, _ address: String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("While you were away", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button { withAnimation { model.dismiss() } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            ForEach(model.entries) { entry in
                Button { open(entry.host, entry.address) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(entry.kind.label)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(color(entry.kind))
                            Text(entry.title).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(entry.machine).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        if let summary = entry.summary {
                            Text(summary).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Summarizing…").font(.footnote).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("away-digest")
    }

    private func color(_ kind: DigestKind) -> Color {
        switch kind {
        case .finished: .green
        case .needsYou: .orange
        case .error: .red
        }
    }
}
