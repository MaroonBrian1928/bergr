import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import bergr

struct TipJarTests {
    @Test func productIDsComeFromTheMainAppsBundleID() {
        let expected = ["com.pavelzw.bergr.tip.small", "com.pavelzw.bergr.tip.medium", "com.pavelzw.bergr.tip.large"]
        #expect(TipProducts.identifiers(bundleID: "com.pavelzw.bergr") == expected)
        #expect(TipProducts.identifiers(bundleID: "com.pavelzw.bergr.dev") == expected)
        #expect(TipProducts.identifiers(bundleID: "com.pavelzw.bergr.mac") == expected)
        #expect(TipProducts.identifiers(bundleID: "com.pavelzw.bergr.mac.dev") == expected)
        #expect(TipProducts.identifier(.small, bundleID: "org.example.bergr.dev") == "org.example.bergr.tip.small")
    }

    @Test func purchaseOutcomesMapToPhases() {
        #expect(TipJarPhase.after(.success) == .thanks)
        #expect(TipJarPhase.after(.pending) == .pending)
        #expect(TipJarPhase.after(.cancelled) == .ready)
        #expect(TipJarPhase.after(.failed("x")) == .failed("x"))
        #expect(TipJarPhase.purchasing("a").isBusy)
        #expect(!TipJarPhase.ready.isBusy)
    }

    @Test func tipsUnlockNothing() {
        #expect(!Entitlements(productIDs: Set(TipProducts.identifiers(bundleID: "com.pavelzw.bergr"))).hasPro)
        #expect(Entitlements(productIDs: ["com.pavelzw.bergr.pro.monthly"]).hasPro)
    }

    /// The products in Config/Tips.storekit load in price order and a purchase ends in thanks.
    @Test(.serialized) func loadsAndBuysWithTheLocalStoreKitConfiguration() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Config/Tips.storekit")
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.clearTransactions()
        let jar = TipJar()
        await jar.load()
        #expect(jar.phase == .ready)
        #expect(jar.tips.map(\.id) == TipProducts.current)
        #expect(jar.tips.first?.price.contains("2.99") == true)
        await jar.buy(try #require(jar.tips.first))
        #expect(jar.phase == .thanks)
    }
}
