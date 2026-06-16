import SwiftUI

@main
struct XsaverApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra("xsaver", systemImage: "arrow.down.circle.dotted") {
            DownloadPanel()
                .environmentObject(state)
        }
        .menuBarExtraStyle(.window)
    }
}
