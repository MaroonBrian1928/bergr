import StoreKit
import SwiftUI

/// Optional tips: three consumable in-app purchases that unlock nothing. No tracking, no prompts
/// elsewhere in the app; the only way in is Settings → About → Support Bergr.
enum TipProducts {
    enum Size: String, CaseIterable, Sendable { case small, medium, large }

    /// The app's own bundle id without the Debug (".dev") and Mac (".mac") suffixes, so Bergr Dev,
    /// Bergr and the Mac app all ask for the same products: `com.pavelzw.bergr.tip.small` and so on.
    nonisolated static func baseIdentifier(bundleID: String) -> String {
        var id = bundleID
        // A Debug Mac build is "….bergr.mac.dev": ".dev" first, then ".mac".
        for suffix in [".dev", ".mac"] where id.hasSuffix(suffix) {
            id.removeLast(suffix.count)
        }
        return id
    }

    nonisolated static func identifier(_ size: Size, bundleID: String) -> String {
        "\(baseIdentifier(bundleID: bundleID)).tip.\(size.rawValue)"
    }

    nonisolated static func identifiers(bundleID: String) -> [String] {
        Size.allCases.map { identifier($0, bundleID: bundleID) }
    }

    static var current: [String] {
        identifiers(bundleID: Store.bundleID)
    }
}

/// What the Support Bergr screen shows.
enum TipJarPhase: Equatable {
    case loading
    case unavailable
    case ready
    case purchasing(String)
    case pending
    case thanks
    case failed(String)

    /// The outcome of a purchase attempt, given where the screen was.
    enum Outcome: Equatable { case success, pending, cancelled, failed(String) }

    static func after(_ outcome: Outcome) -> TipJarPhase {
        switch outcome {
        case .success: .thanks
        case .pending: .pending
        case .cancelled: .ready
        case .failed(let message): .failed(message)
        }
    }

    var isBusy: Bool {
        if case .purchasing = self { return true }
        return false
    }
}

/// Loads the tip products and buys them.
@Observable
final class TipJar {
    struct Tip: Identifiable, Equatable {
        let id: String
        let name: String
        let price: String
    }

    private(set) var phase: TipJarPhase = .loading
    private(set) var tips: [Tip] = []
    private var products: [String: Product] = [:]

    /// Sorts tips by price (small, medium, large), whatever order the store returns.
    static func ordered(_ products: [Product]) -> [Product] {
        products.sorted { $0.price < $1.price }
    }

    func load() async {
        phase = .loading
        do {
            let found = Self.ordered(try await Store.shared.products(TipProducts.current))
            products = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            tips = found.map { Tip(id: $0.id, name: $0.displayName, price: $0.displayPrice) }
            phase = tips.isEmpty ? .unavailable : .ready
        } catch {
            phase = .unavailable
        }
    }

    func buy(_ tip: Tip) async {
        guard let product = products[tip.id], !phase.isBusy else { return }
        phase = .purchasing(tip.id)
        phase = TipJarPhase.after(await Store.shared.purchase(product))
    }

    func reset() { phase = tips.isEmpty ? .unavailable : .ready }
}

/// Settings → About → Support Bergr.
struct TipJarView: View {
    @State private var jar = TipJar()

    var body: some View {
        Form {
            Section {
                Text("Bergr is free and open source. Tips help keep it going; they don't unlock anything.")
                    .foregroundStyle(.secondary)
            }
            Section {
                content
            }
        }
        .bergrTint()
        .navigationTitle("Support Bergr")
        .inlineNavigationTitle()
        .task { await jar.load() }
    }

    @ViewBuilder private var content: some View {
        switch jar.phase {
        case .loading:
            HStack { Spacer(); ProgressView(); Spacer() }
        case .unavailable:
            Text("Tips aren't available right now. Thanks for thinking of it.")
                .foregroundStyle(.secondary)
        case .thanks:
            Label("Thank you! That means a lot.", systemImage: "heart.fill")
            Button("Done") { jar.reset() }
        case .pending:
            Text("Your tip is waiting for approval. Thank you!")
                .foregroundStyle(.secondary)
            Button("OK") { jar.reset() }
        case .failed(let message):
            Text("The tip didn't go through. \(message)")
                .foregroundStyle(.secondary)
            Button("Try again") { jar.reset() }
        case .ready, .purchasing:
            ForEach(jar.tips) { tip in
                Button {
                    Task { await jar.buy(tip) }
                } label: {
                    HStack {
                        Text(tip.name).foregroundStyle(.primary)
                        Spacer()
                        if jar.phase == .purchasing(tip.id) {
                            ProgressView()
                        } else {
                            Text(tip.price).monospacedDigit()
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(jar.phase.isBusy)
                .accessibilityIdentifier("tip-\(tip.id.split(separator: ".").last ?? "")")
            }
        }
    }
}
