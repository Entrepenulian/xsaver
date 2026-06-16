import SwiftUI

@main
struct XsaverApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra("xsaver", image: "XLogo") {
            DownloadPanel()
                .environmentObject(state)
        }
        .menuBarExtraStyle(.window)
    }
}
