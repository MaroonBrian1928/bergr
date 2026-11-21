import Foundation
import HerdrKit

/// What a working agent is doing, in the on-device model's words: a live line under its row in
/// the Agents list ("Running the test suite after fixing the parser"), and a short paragraph on
/// request. Written from the agent's recent chat (only for chats Bergr is following), on the
/// device; without Apple Intelligence there's simply no line.
@MainActor @Observable
final class AgentActivity {
    static let shared = AgentActivity(writer: OnDeviceText.shared)

    struct Entry: Equatable {
        var line: String?
        var detail: String?
        /// The transcript the line was written from, so an unchanged chat isn't asked about again.
        var basis: Int
        var at: Date
    }

    /// A line is written again at most this often while the agent works.
    static let lineEvery: TimeInterval = 25
    static let window = 10
    static let detailWindow = 30

    static let lineInstructions = """
        You describe what a coding agent is doing right now, from the end of its session. Answer \
        with one plain-text phrase of at most 12 words that starts with a verb in the -ing form \
        ("Running the tests after fixing the parser"). No markdown, no quotes, no trailing period.
        """
    static let detailInstructions = """
        You explain to the agent's owner what a coding agent is doing, from the end of its session. \
        Answer in at most 4 short plain-text sentences: what it is working on, what it just did, \
        and anything it is stuck on or waiting for. No markdown, no lists, no quotes.
        """

    private(set) var entries: [String: Entry] = [:]
    @ObservationIgnored private var asking: Set<String> = []
    @ObservationIgnored private let writer: OnDeviceTextWriting

    init(writer: OnDeviceTextWriting) { self.writer = writer }

    static func key(host: UUID, address: String) -> String { "\(host.uuidString)|\(address)" }

    func line(host: UUID, address: String) -> String? { entries[Self.key(host: host, address: address)]?.line }
    func detail(host: UUID, address: String) -> String? { entries[Self.key(host: host, address: address)]?.detail }

    /// Writes a new line when the chat changed and the last one is older than `lineEvery`.
    func refreshLine(host: UUID, address: String, agent: String, items: [ChatFeed.Item], now: Date = .now) async {
        let key = Self.key(host: host, address: address)
        let transcript = NotificationSummary.transcript(items, last: Self.window)
        guard !transcript.isEmpty else { return }
        let basis = transcript.hashValue
        if let old = entries[key] {
            if old.basis == basis { return }
            // Too soon after the last line: wait out the rest, then write it (the chat may not
            // change again, as when the agent starts a long command).
            let wait = Self.lineEvery - now.timeIntervalSince(old.at)
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                return await refreshLine(host: host, address: address, agent: agent, items: items)
            }
        }
        guard !asking.contains(key) else { return }
        asking.insert(key)
        defer { asking.remove(key) }
        let prompt = Self.prompt(agent: agent, transcript: transcript)
        guard let text = await writer.write(instructions: Self.lineInstructions, prompt: prompt, timeout: .seconds(8)),
              let line = OnDeviceText.clean(text, maxCharacters: 90) else { return }
        var entry = entries[key] ?? Entry(basis: basis, at: now)
        entry.line = line.hasSuffix(".") ? String(line.dropLast()) : line
        entry.basis = basis
        entry.at = now
        entries[key] = entry
    }

    /// A short paragraph on what it's doing, for the sheet; nil when the model can't.
    func writeDetail(host: UUID, address: String, agent: String, items: [ChatFeed.Item]) async -> String? {
        let transcript = NotificationSummary.transcript(items, last: Self.detailWindow)
        guard !transcript.isEmpty else { return nil }
        let prompt = Self.prompt(agent: agent, transcript: transcript)
        guard let text = await writer.write(instructions: Self.detailInstructions, prompt: prompt, timeout: .seconds(15))
        else { return nil }
        let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty, !OnDeviceText.isRefusal(detail) else { return nil }
        let key = Self.key(host: host, address: address)
        var entry = entries[key] ?? Entry(basis: 0, at: .distantPast)
        entry.detail = detail
        entries[key] = entry
        return detail
    }

    static func prompt(agent: String, transcript: [String]) -> String {
        OnDeviceText.truncate("Agent: \(agent)\nThe end of its session, oldest first:\n"
            + transcript.joined(separator: "\n"), to: NotificationSummary.promptCharacters * 2)
    }
}

import SwiftUI

/// "What's it doing?": a few sentences from the on-device model on an agent's recent chat, with
/// the latest steps it took underneath.
struct AgentActivitySheet: View {
    let name: String
    let host: UUID
    let address: String
    let agent: String
    let feed: ChatFeed?
    @State private var detail: String?
    @State private var writing = true
    @Environment(\.dismiss) private var dismiss
    private let activity = AgentActivity.shared

    private var steps: [String] {
        guard let feed else { return [] }
        return feed.items.suffix(40).compactMap { item -> String? in
            if case .tool(let name, let summary) = item.kind { return summary.isEmpty ? name : "\(name): \(summary)" }
            return nil
        }.suffix(8).reversed()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let detail {
                        Text(detail).fixedSize(horizontal: false, vertical: true)
                    } else if writing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Reading its chat…").foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Couldn't write a summary right now.").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Written on this device by Apple Intelligence from the agent's recent chat.")
                }
                if !steps.isEmpty {
                    Section("Latest steps") {
                        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                            Text(step).font(.footnote.monospaced()).lineLimit(2)
                        }
                    }
                }
            }
            .navigationTitle(name)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                detail = activity.detail(host: host, address: address)
                defer { writing = false }
                guard let feed else { return }
                if let fresh = await activity.writeDetail(host: host, address: address, agent: agent, items: feed.items) {
                    detail = fresh
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
