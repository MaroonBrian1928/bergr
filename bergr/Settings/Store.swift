import StoreKit

/// The app's one StoreKit layer: loads products, buys them, finishes transactions and keeps
/// `entitlements` current. Today it only sells tips (consumables, `<app>.tip.*`) that unlock
/// nothing. A later subscription (e.g. `<app>.pro.monthly`, in its own subscription group) plugs in
/// here: its products show up in `Transaction.currentEntitlements`, `Entitlements.hasPro` turns
/// true, and features read `Store.shared.entitlements`. Nothing is gated on it yet.
@Observable
final class Store {
    static let shared = Store()

    /// The main app's bundle id, the base for every product id (see `TipProducts.baseIdentifier`).
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.pavelzw.bergr" }

    private(set) var entitlements = Entitlements(productIDs: [])
    private var listener: Task<Void, Never>?

    /// Called once at launch: finishes transactions that complete outside a purchase sheet (Ask to
    /// Buy, interrupted purchases), so none stay unfinished, and reads the current entitlements.
    func start() {
        guard listener == nil else { return }
        listener = Task { [weak self] in
            await self?.refreshEntitlements()
            for await update in Transaction.updates {
                if case .verified(let transaction) = update { await transaction.finish() }
                await self?.refreshEntitlements()
            }
        }
    }

    func products(_ ids: [String]) async throws -> [Product] {
        try await Product.products(for: ids)
    }

    func purchase(_ product: Product) async -> TipJarPhase.Outcome {
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await transaction.finish()
                await refreshEntitlements()
                return .success
            case .success(.unverified):
                return .failed("The App Store couldn't verify this purchase.")
            case .pending: return .pending
            case .userCancelled: return .cancelled
            @unknown default: return .cancelled
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func refreshEntitlements() async {
        var ids: Set<String> = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.revocationDate == nil {
                ids.insert(transaction.productID)
            }
        }
        entitlements = Entitlements(productIDs: ids)
    }
}

/// What the user owns. Consumable tips never appear here; a future `.pro.*` subscription would.
struct Entitlements: Equatable, Sendable {
    let productIDs: Set<String>

    /// Infix of a future Pro subscription's product ids (`<app>.pro.monthly`, `<app>.pro.yearly`).
    nonisolated static let proInfix = ".pro."

    var hasPro: Bool { productIDs.contains { $0.contains(Self.proInfix) } }
}
