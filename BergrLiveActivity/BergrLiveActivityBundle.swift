import SwiftUI
import WidgetKit

@main
struct BergrLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        AgentsLiveActivity()
        AgentsWidget()
        NeedsYouControl()
    }
}
