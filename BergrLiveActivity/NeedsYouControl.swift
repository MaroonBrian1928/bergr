import SwiftUI
import WidgetKit

/// Control Center (and the Action button, where it's assigned): opens Bergr at the agents that need you.
struct NeedsYouControl: ControlWidget {
    static let kind = "BergrNeedsYouControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenNeedsYouIntent()) {
                Label("Needs you", systemImage: "exclamationmark.bubble.fill")
            }
        }
        .displayName("Agents that need you")
        .description("Opens Bergr at the agents that need you.")
    }
}
