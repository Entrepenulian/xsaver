import SwiftUI

@main
struct XsaverApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            DownloadPanel()
                .environmentObject(state)
        } label: {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 18, weight: .medium)) // renders ~18x18px visible
        }
        .menuBarExtraStyle(.window)
    }
}
