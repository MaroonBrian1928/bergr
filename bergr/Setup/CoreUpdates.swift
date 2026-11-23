import Foundation
import HerdrKit
import SwiftUI

/// The newest herdr-core release, as Herdr itself checks it (`releases.herdr.dev/core/latest.json`),
/// so a machine running an older one can offer an update like the Claude Code banner in a chat.
@MainActor @Observable
final class CoreUpdates {
    static let shared = CoreUpdates()

    struct Release: Decodable, Equatable {
        var version: String
        var generation: Int?
        var notes: String?
    }

    static let latestURL = URL(string: "https://releases.herdr.dev/core/latest.json")!
    /// Checked at most this often (a failed check may be retried sooner).
    static let every: TimeInterval = 6 * 3600
    static let retryAfter: TimeInterval = 10 * 60

    private(set) var latest: Release?
    @ObservationIgnored private var checkedAt: Date?
    @ObservationIgnored private var checking = false

    func refresh(now: Date = .now) async {
        if checking { return }
        if let checkedAt, now.timeIntervalSince(checkedAt) < (latest == nil ? Self.retryAfter : Self.every) { return }
        checking = true
        defer { checking = false }
        checkedAt = now
        var request = URLRequest(url: Self.latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data) else { return }
        latest = release
    }

    /// The newer release for a machine running `version`, or nil when it's current or unreadable.
    static func newer(than version: String?, latest: Release?) -> Release? {
        guard let version, let latest, SetupCheck.isOlder(version, than: latest.version) else { return nil }
        return latest
    }

    /// Runs herdr-core's own updater on the machine: it swaps the binary and restarts the core,
    /// keeping terminals running (a newer protocol generation is refused without --force).
    /// Run through herdr-core itself (`machine.exec`), so it works however Bergr reaches the core.
    static let unixUpdate = ["sh", "-c", #"p=$(command -v herdr-core) || p="$HOME/.local/bin/herdr-core"; "$p" update --json 2>&1"#]
    static let windowsUpdate = ["cmd", "/d", "/s", "/c",
                                #""%LOCALAPPDATA%\Programs\herdr-core\herdr-core.exe" update --json 2>&1"#]

    /// herdr-core's error message from `update --json` output, if it printed one.
    static func failure(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let error = json["error"] as? [String: Any] else { continue }
            return (error["message"] as? String) ?? "the update failed"
        }
        return nil
    }
}

/// A newer herdr-core is out than this machine runs: one tap updates it, terminals keep running.
struct CoreUpdateBanner: View {
    let session: HostSession
    /// In a List row (the Agents list): names the machine, no outer padding.
    var inList = false
    @State private var updating = false
    @State private var error: String?
    @State private var showingNotes = false
    @AppStorage("coreUpdate.dismissed") private var dismissed = ""
    private let updates = CoreUpdates.shared

    private var dismissKey: String { "\(session.host.id.uuidString)|" }

    var body: some View {
        Group {
            if !session.host.isDemo, session.state == .connected,
               let release = CoreUpdates.newer(than: session.coreVersion, latest: updates.latest),
               !dismissed.contains(dismissKey + release.version) {
                banner(release)
                    .padding(.horizontal, inList ? 0 : 12)
                    .padding(.bottom, inList ? 0 : 6)
                    .transition(.opacity)
            }
        }
        .task { await updates.refresh() }
    }

    private func banner(_ release: CoreUpdates.Release) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(inList ? "\(session.host.name): herdr-core \(release.version) is available"
                     : "herdr-core \(release.version) is available")
                    .font(.footnote.weight(.semibold))
                Text(error ?? (updating ? "Updating… your terminals keep running."
                               : "This machine runs \(session.coreVersion ?? "an older version"). Updating keeps your terminals running."))
                    .font(.caption)
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
                if release.notes?.isEmpty == false {
                    Button("What's new") { showingNotes = true }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
            Spacer(minLength: 0)
            if updating {
                ProgressView().frame(width: 60)
            } else {
                Button(error == nil ? "Update" : "Retry") { Task { await update() } }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                Button("Not now", systemImage: "xmark") {
                    dismissed = dismissed.split(separator: ",").filter { !$0.hasPrefix(dismissKey) }
                        .map(String.init).appending(dismissKey + release.version).joined(separator: ",")
                }
                .labelStyle(.iconOnly)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .sheet(isPresented: $showingNotes) {
            NavigationStack {
                ScrollView {
                    Text((try? AttributedString(markdown: release.notes ?? "",
                                                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                         ?? AttributedString(release.notes ?? ""))
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle("herdr-core \(release.version)")
                .inlineNavigationTitle()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingNotes = false } } }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func update() async {
        updating = true
        error = nil
        defer { updating = false }
        // The core restarts partway through, which can cut this command's line: an error from
        // herdr-core is reported; a dropped line is expected, and the reconnect shows the version.
        let argv = session.isWindowsHost ? CoreUpdates.windowsUpdate : CoreUpdates.unixUpdate
        do {
            let out = try await session.exec(argv, timeout: 180)
            if let failure = CoreUpdates.failure(out.stdout + "\n" + out.stderr) {
                error = failure
                return
            }
        } catch {
            // The line dropping as the core restarts is expected; anything else shows below.
        }
        // Wait for the reconnect to report the new version.
        for _ in 0..<30 {
            if CoreUpdates.newer(than: session.coreVersion, latest: updates.latest) == nil { return }
            try? await Task.sleep(for: .seconds(2))
        }
        error = "Still on \(session.coreVersion ?? "the old version"). Pull to refresh, or run hc update on the machine."
    }
}

private extension Array {
    func appending(_ element: Element) -> [Element] { self + [element] }
}
