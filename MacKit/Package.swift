// swift-tools-version: 6.2
import PackageDescription

// Mac-only dependencies of the `bergrMac` target, in a package of their own so that the iOS app
// never resolves or links them. (The project file's remote-package syntax isn't documented; a
// local package that depends on remote ones is how HerdrKit does it too.)
let package = Package(
    name: "MacKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MacKit", targets: ["MacKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "MacKit", dependencies: [.product(name: "Sparkle", package: "Sparkle")]),
    ]
)
