import HerdrKit
import SwiftUI

/// A blocked agent waits for an answer: the usual replies as buttons, so there's no need to type.
struct NeedsYouBar: View {
    let status: TerminalStatus?
    let model: TerminalScreenModel
    var dark = true
    /// Called with the answer given, for the chat's record.
    var onAnswer: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(status?.title ?? "Waiting for you").lineLimit(2)
            } icon: {
                Image(systemName: "hand.raised.fill").foregroundStyle(Color.needsYou)
            }
            .font(.callout.weight(.semibold))
            HStack(spacing: 8) {
                Button { onAnswer?("Yes"); model.type("y") } label: {
                    Label("Yes", systemImage: "checkmark").fixedSize().frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.needsYou)
                .foregroundStyle(Color(red: 0x30 / 255, green: 0x34 / 255, blue: 0x38 / 255))
                Button { onAnswer?("No"); model.type("n") } label: {
                    Label("No", systemImage: "xmark").fixedSize().frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button { onAnswer?("Return"); model.press(.enter) } label: { Image(systemName: "return").fixedSize() }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Return")
                Button { onAnswer?("Cancelled (esc)"); model.press(.escape) } label: { Text("esc").font(.callout.monospaced()).fixedSize() }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Escape")
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}
