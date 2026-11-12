import HerdrKit
import SwiftUI

/// The search results as list sections, one per machine. A hit's live agent opens its chat;
/// otherwise the conversation's details show (resuming from here isn't available).
struct SearchResultsSections: View {
    let model: TranscriptSearchModel
    let sessions: SessionStore
    let open: (_ host: Host.ID, _ address: String) -> Void

    var body: some View {
        ForEach(model.results) { machine in
            Section {
                if machine.searching {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Searching…").foregroundStyle(.secondary) }
                        .selectionDisabled()
                }
                if let error = machine.error {
                    Text(error).font(.footnote).foregroundStyle(.secondary).selectionDisabled()
                }
                if !machine.searching, machine.error == nil, machine.hits.isEmpty {
                    Text("No matches.").font(.footnote).foregroundStyle(.tertiary).selectionDisabled()
                }
                ForEach(machine.hits) { hit in
                    Button { pick(hit, machine.host) } label: { SearchHitRow(hit: hit) }
                        .buttonStyle(.plain)
                }
                if machine.truncated {
                    Text("Showing the newest matches.").font(.caption).foregroundStyle(.tertiary).selectionDisabled()
                }
            } header: {
                Text(machine.host.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).textCase(nil)
            }
        }
        if model.results.isEmpty {
            Text("No connected machine can search.").font(.footnote).foregroundStyle(.tertiary).selectionDisabled()
        }
    }

    private func pick(_ hit: SearchHit, _ host: Host) {
        let terminals = sessions.existing(host.id)?.terminals ?? []
        if let live = TranscriptSearch.liveTerminal(for: hit, in: terminals) {
            open(host.id, live.address)
        } else {
            model.info = hit
        }
    }
}

extension SearchResultsSections {
    /// Wraps the sections' owner view with the "not live" alert.
    struct InfoAlert: ViewModifier {
        @Binding var hit: SearchHit?
        func body(content: Content) -> some View {
            content.alert(hit?.displayTitle ?? "", isPresented: Binding(get: { hit != nil }, set: { if !$0 { hit = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                if let hit {
                    Text("\(hit.agentName) in \(hit.cwd.isEmpty ? "an unknown folder" : hit.cwd), \(hit.date.formatted(date: .abbreviated, time: .shortened)). This agent isn't running; resuming it from Bergr isn't available. Resume it on the machine with its session ID \(hit.session).")
                }
            }
        }
    }
}

private struct SearchHitRow: View {
    let hit: SearchHit
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hit.displayTitle).fontWeight(.medium).lineLimit(1)
            Text(hit.snippet).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
            HStack(spacing: 6) {
                Text(hit.agentName)
                if !hit.folder.isEmpty { Text("·"); Text(hit.folder) }
                Text("·")
                Text(hit.date, format: .dateTime.month(.abbreviated).day().hour().minute())
            }
            .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
