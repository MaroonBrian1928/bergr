import SwiftUI

/// App-wide settings, and what Hirte is.
struct SettingsView: View {
    @Environment(HostStore.self) private var hosts
    @AppStorage(TerminalFont.sizeKey) private var fontSize = TerminalFont.defaultSize
    @AppStorage(TerminalFont.storageKey) private var fontFamily = TerminalFont.jetBrainsMono
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @AppStorage(TerminalTheme.lightKey) private var lightTheme = TerminalTheme.defaultLight
    @AppStorage(TerminalTheme.darkKey) private var darkTheme = TerminalTheme.defaultDark
    @Environment(\.colorScheme) private var colorScheme
    /// Adds the demo machine and shows it.
    var addDemo: () -> Void = {}

    private static let website = URL(string: "https://hirte.dev")!
    private static let sourceCode = URL(string: "https://github.com/glattziehen/hirte")!

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                TerminalPreview(
                    size: fontSize, family: fontFamily,
                    theme: TerminalTheme.current(colorScheme, light: lightTheme, dark: darkTheme))
                    .listRowInsets(EdgeInsets())
                NavigationLink {
                    ThemePicker(title: "Light Theme", themes: TerminalTheme.lightThemes, selection: $lightTheme)
                } label: {
                    LabeledContent("Light Theme", value: TerminalTheme.find(lightTheme, dark: false).name)
                }
                NavigationLink {
                    ThemePicker(title: "Dark Theme", themes: TerminalTheme.darkThemes, selection: $darkTheme)
                } label: {
                    LabeledContent("Dark Theme", value: TerminalTheme.find(darkTheme, dark: true).name)
                }
                Picker("Font", selection: $fontFamily) {
                    ForEach(TerminalFont.allCases) { Text($0.title).tag($0) }
                }
                Stepper(value: $fontSize, in: 7...28, step: 1) {
                    LabeledContent("Size", value: "\(fontSize.formatted(.number.precision(.fractionLength(0...1)))) pt")
                }
            } header: {
                Text("Terminal")
            } footer: {
                Text("The terminal uses the light or dark theme to match the appearance. Pinch a terminal to change the size there too.")
            }

            Section {
                Button(hosts.hasDemo ? "Show Demo Machine" : "Add Demo Machine", systemImage: "play.rectangle") {
                    addDemo()
                }
            } footer: {
                Text("A machine built into Hirte, with agents and terminals to try everything without a server.")
            }

            Section("About") {
                LabeledContent("Version", value: Self.version)
                Link(destination: Self.website) {
                    Label("Website", systemImage: "globe")
                }
                Link(destination: Self.website.appending(path: "support/")) {
                    Label("Support", systemImage: "questionmark.circle")
                }
                Link(destination: Self.website.appending(path: "privacy/")) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                Link(destination: Self.sourceCode) {
                    Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                NavigationLink {
                    LicensesView()
                } label: {
                    Label("Open-Source Licenses", systemImage: "doc.text")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// A few lines in a theme and font, so changes show at once.
private struct TerminalPreview: View {
    let size: Double
    let family: TerminalFont
    let theme: TerminalTheme

    var body: some View {
        let fonts = Fonts(size: size, family: family)
        VStack(alignment: .leading, spacing: 0) {
            Self.line([("~/projects/shop-api ", theme.ansiColor(4)), ("❯ ", theme.ansiColor(5)), ("git log --oneline", nil)])
            Self.line([("a41c9e2 ", theme.ansiColor(3)), ("Add order totals endpoint", nil)])
            Self.line([("7d03b1f ", theme.ansiColor(3)), ("Cache product images", nil)])
            Self.line([("✓ ", theme.ansiColor(2)), ("48 passed ", nil), ("✗ ", theme.ansiColor(1)), ("0 failed", nil)])
        }
        .font(Font(fonts.regular))
        .foregroundStyle(theme.color(theme.foreground))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(theme.color(theme.background))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview of \(theme.name) in \(family.title)")
    }

    /// One line from colored pieces (nil: the theme's foreground).
    static func line(_ pieces: [(String, Color?)]) -> Text {
        var text = AttributedString()
        for (string, color) in pieces {
            var piece = AttributedString(string)
            if let color { piece.foregroundColor = color }
            text += piece
        }
        return Text(text)
    }
}

/// Every light (or dark) theme, each drawn in its own colors.
private struct ThemePicker: View {
    let title: String
    let themes: [TerminalTheme]
    @Binding var selection: String

    var body: some View {
        List(themes) { theme in
            Button {
                selection = theme.id
            } label: {
                HStack(spacing: 12) {
                    ThemeSwatch(theme: theme)
                    Text(theme.name).foregroundStyle(.primary)
                    Spacer()
                    if theme.id == selection {
                        Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                    }
                }
            }
            .accessibilityAddTraits(theme.id == selection ? .isSelected : [])
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A theme at a glance: its background with a prompt and the six main colors.
private struct ThemeSwatch: View {
    let theme: TerminalTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TerminalPreview.line([("❯ ", theme.ansiColor(5)), ("ls", nil)])
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.color(theme.foreground))
            HStack(spacing: 3) {
                ForEach(1..<7) { index in
                    Circle().fill(theme.ansiColor(index)).frame(width: 7, height: 7)
                }
            }
        }
        .padding(8)
        .frame(width: 84, alignment: .leading)
        .background(theme.color(theme.background), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.quaternary))
        .accessibilityHidden(true)
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .environment(HostStore())
}
