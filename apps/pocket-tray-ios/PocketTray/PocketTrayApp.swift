import SwiftUI

@main
struct PocketTrayApp: App {
    private let tray: Tray
    @StateObject private var appLockController: AppLockController

    init() {
        let repository: any TrayRepository
        do {
            repository = try FileTrayRepository.sharedContainer()
        } catch {
            repository = UnavailableTrayRepository()
        }
        tray = Tray(repository: repository, analyzer: AppleContentAnalyzer())
        _appLockController = StateObject(wrappedValue: AppLockController())
    }

    var body: some Scene {
        WindowGroup {
            AppLockGate(controller: appLockController) {
                RootView(tray: tray, appLockController: appLockController)
            }
        }
    }
}
