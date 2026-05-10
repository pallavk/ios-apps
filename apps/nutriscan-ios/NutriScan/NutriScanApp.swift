import SwiftData
import SwiftUI

@main
struct NutriScanApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: SavedScan.self)
    }
}
