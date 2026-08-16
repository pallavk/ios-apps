import SwiftUI

@main
struct PocketTrayApp: App {
    private let tray = Tray(repository: FileTrayRepository.applicationSupport())

    var body: some Scene {
        WindowGroup {
            RootView(tray: tray)
        }
    }
}
