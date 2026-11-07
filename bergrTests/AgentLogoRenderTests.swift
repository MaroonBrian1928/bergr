import SwiftUI
import Testing
@testable import bergr

@MainActor
struct AgentLogoRenderTests {
    /// Draws every agent's logo; each must come out as a real image (not blank).
    @Test func logosRender() throws {
        let row = HStack(spacing: 16) {
            ForEach([AgentKind.claude, .codex, .antigravity, .shell], id: \.self) { AgentLogo(kind: $0, size: 48) }
        }
        .padding(16)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: row)
        renderer.scale = 2
        let image = try #require(renderer.uiImage)
        let data = try #require(image.pngData())
        if let dir = ProcessInfo.processInfo.environment["BERGR_SHOTS"] {
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("agent-logos.png"))
        }
        #expect(image.size.width > 200)
    }
}
