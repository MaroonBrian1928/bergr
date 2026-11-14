#if os(macOS)
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Mac Settings → "Pair iPhone…": pick machines, show a QR code, wait for the phone's key, then
/// add it to each machine's `authorized_keys` through the system ssh.
struct PairPhoneView: View {
    @Environment(HostStore.self) private var hosts
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case choosing
        case showing(PairingOffer)
        case confirm(PairedKey, [PairingHost])
        case installing([PairingHost: AuthorizedKeysInstall.Outcome?])
        case failed(String)
    }

    @State private var phase = Phase.choosing
    @State private var excluded: Set<UUID> = []
    @State private var chosen: [PairingHost] = []

    private var machines: [Host] { hosts.hosts.filter { !$0.isLocal && !$0.isDemo } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair iPhone").font(.title2.bold())
            content
            HStack {
                Spacer()
                Button(isFinished ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                primaryButton
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var isFinished: Bool {
        if case .installing(let results) = phase { return !results.values.contains(where: { $0 == nil }) }
        return false
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .choosing:
            Text("Choose the machines to set up on your iPhone.").foregroundStyle(.secondary)
            if machines.isEmpty {
                Text("Add a machine first.").foregroundStyle(.secondary)
            }
            ForEach(machines) { host in
                Toggle(isOn: Binding(get: { !excluded.contains(host.id) },
                                     set: { if $0 { excluded.remove(host.id) } else { excluded.insert(host.id) } })) {
                    VStack(alignment: .leading) {
                        Text(host.name)
                        Text(host.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        case .showing(let offer):
            HStack(alignment: .top, spacing: 16) {
                QRCode(text: offer.payload.encoded()).frame(width: 220, height: 220)
                VStack(alignment: .leading, spacing: 8) {
                    Text("In Bergr on your iPhone, tap + and Scan from Mac.")
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, Int(offer.expires.timeIntervalSince(context.date)))
                        Text("Expires in \(left / 60):\(String(format: "%02d", left % 60))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    ProgressView().controlSize(.small)
                }
            }
            .task(id: offer.payload.token) { await poll(offer) }
        case .confirm(let key, let targets):
            Text("Add this iPhone's key (\(key.fingerprint), \(key.comment.isEmpty ? "no comment" : key.comment)) to \(targets.count) machines?")
                .fixedSize(horizontal: false, vertical: true)
        case .installing(let results):
            ForEach(chosen, id: \.self) { host in
                HStack {
                    Text(host.name)
                    Spacer()
                    if let outcome = results[host] ?? nil {
                        Text(outcome.message).font(.caption)
                            .foregroundStyle(outcome == .added || outcome == .alreadyPresent ? Color.secondary : Color.orange)
                            .multilineTextAlignment(.trailing)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        case .failed(let message):
            Text(message).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch phase {
        case .choosing:
            Button("Show Code") { start() }
                .keyboardShortcut(.defaultAction)
                .disabled(machines.allSatisfy { excluded.contains($0.id) })
        case .confirm(let key, let targets):
            Button("Add Key") { Task { await install(key, on: targets) } }.keyboardShortcut(.defaultAction)
        case .failed:
            Button("Try Again") { phase = .choosing }.keyboardShortcut(.defaultAction)
        default:
            EmptyView()
        }
    }

    private func start() {
        chosen = machines.filter { !excluded.contains($0.id) }.map(PairingHost.init)
        phase = .showing(PairingOffer(relay: PushRegistration.relayURL, hosts: chosen))
    }

    private func poll(_ offer: PairingOffer) async {
        guard let url = offer.mailboxURL else { return }
        while !Task.isCancelled {
            if offer.isExpired() {
                phase = .failed("The code expired. Show a new one to try again.")
                return
            }
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                do {
                    let line = try offer.open(String(decoding: data, as: UTF8.self))
                    guard let key = PairedKey(line) else { throw PairingError.invalid("key") }
                    phase = .confirm(key, chosen)
                } catch {
                    phase = .failed(error.localizedDescription)
                }
                return
            }
            try? await Task.sleep(for: Pairing.pollInterval)
        }
    }

    private func install(_ key: PairedKey, on targets: [PairingHost]) async {
        var results: [PairingHost: AuthorizedKeysInstall.Outcome?] = [:]
        for host in targets { results[host] = .some(nil) }
        phase = .installing(results)
        for host in targets {
            let outcome = await AuthorizedKeysInstall.run(key, on: host)
            results[host] = outcome
            phase = .installing(results)
        }
    }
}

private struct QRCode: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
        } else {
            Color.secondary.opacity(0.2)
        }
    }

    static func render(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
#endif
