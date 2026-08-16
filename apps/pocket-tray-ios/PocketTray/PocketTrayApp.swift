import SwiftUI

@main
struct PocketTrayApp: App {
    private let tray: Tray

    init() {
        let repository: any TrayRepository
        do {
            repository = try FileTrayRepository.sharedContainer()
        } catch {
            repository = UnavailableTrayRepository()
        }
        tray = Tray(repository: repository)
    }

    var body: some Scene {
        WindowGroup {
            RootView(tray: tray)
        }
    }
}
