import Foundation

/// The terminal fonts to choose from in Settings.
enum TerminalFont: String, CaseIterable, Identifiable {
    /// Bundled in `bergr/Fonts` (SIL OFL 1.1).
    case jetBrainsMono
    /// The system's monospaced font.
    case sfMono
    case menlo
    /// Bundled (MIT); regular and bold only, so italic text shows upright.
    case comicMono

    var id: Self { self }

    var title: String {
        switch self {
        case .jetBrainsMono: "JetBrains Mono"
        case .sfMono: "SF Mono"
        case .menlo: "Menlo"
        case .comicMono: "Comic Mono"
        }
    }

    /// PostScript names: regular, bold, italic, bold italic. Nil: the system font.
    var names: [String?] {
        switch self {
        case .jetBrainsMono: ["JetBrainsMono-Regular", "JetBrainsMono-Bold", "JetBrainsMono-Italic", "JetBrainsMono-BoldItalic"]
        case .sfMono: [nil, nil, nil, nil]
        case .menlo: ["Menlo-Regular", "Menlo-Bold", "Menlo-Italic", "Menlo-BoldItalic"]
        case .comicMono: ["ComicMono", "ComicMono-Bold", nil, nil]
        }
    }

    static let storageKey = "terminal.font"
    static let sizeKey = "terminal.fontSize"
    static let defaultSize = 13.0
}
