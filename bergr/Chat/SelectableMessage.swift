import Foundation

/// A message to pick part of. Long-pressing a message copies all of it; "Select Text" opens it
/// here, where any part can be selected and copied.
struct SelectableMessage: Identifiable {
    let id = UUID()
    let text: String
}
