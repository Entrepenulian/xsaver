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
                .font(.system(size: 22, weight: .medium)) // renders ~22x22px visible
        }
        .menuBarExtraStyle(.window)
    }
}
