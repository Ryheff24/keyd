import WidgetKit
import SwiftUI

/// @main entry point for the KeydLiveActivity Widget Extension.
/// This extension renders the Dynamic Island and Lock Screen Live Activity views.
/// The main app (KeydLiveActivityManager) requests/updates the activity;
/// iOS calls this extension to render it.
@main
struct KeydLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        KeydLiveActivityWidget()
    }
}
