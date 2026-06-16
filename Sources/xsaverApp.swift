import SwiftUI

@main
struct XsaverApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            DownloadPanel()
                .environmentObject(state)
        } label: {
            Image(systemName: "arrow.down.circle.dotted")
                .font(.system(size: 18, weight: .medium))
        }
        .menuBarExtraStyle(.window)
    }
}
