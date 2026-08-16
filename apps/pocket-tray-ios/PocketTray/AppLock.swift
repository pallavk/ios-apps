import Foundation
import LocalAuthentication
import SwiftUI

@MainActor
protocol AppLockSettings: AnyObject {
    var isAppLockEnabled: Bool { get set }
}

@MainActor
final class UserDefaultsAppLockSettings: AppLockSettings {
    private enum Key {
        static let isEnabled = "appLock.isEnabled"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: FileTrayRepository.appGroupIdentifier)) {
        self.defaults = defaults ?? .standard
    }

    var isAppLockEnabled: Bool {
        get { defaults.bool(forKey: Key.isEnabled) }
        set { defaults.set(newValue, forKey: Key.isEnabled) }
    }
}

@MainActor
protocol AppAuthenticating: AnyObject {
    func authenticate() async -> Bool
}

@MainActor
final class SystemAppAuthenticator: AppAuthenticating {
    func authenticate() async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock Pocket Tray"
            )
        } catch {
            return false
        }
    }
}

@MainActor
final class AppLockController: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isLocked: Bool
    @Published private(set) var errorMessage: String?

    private let settings: any AppLockSettings
    private let authenticator: any AppAuthenticating

    init(
        settings: any AppLockSettings = UserDefaultsAppLockSettings(),
        authenticator: any AppAuthenticating = SystemAppAuthenticator()
    ) {
        self.settings = settings
        self.authenticator = authenticator
        isEnabled = settings.isAppLockEnabled
        isLocked = settings.isAppLockEnabled
    }

    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        if enabled {
            guard await authenticator.authenticate() else {
                errorMessage = "Pocket Tray could not verify your identity. App Lock remains off."
                return
            }
            settings.isAppLockEnabled = true
            isEnabled = true
            isLocked = false
            errorMessage = nil
        } else {
            settings.isAppLockEnabled = false
            isEnabled = false
            isLocked = false
            errorMessage = nil
        }
    }

    func sceneDidEnterBackground() {
        guard isEnabled else { return }
        isLocked = true
        errorMessage = nil
    }

    func unlock() async {
        guard isEnabled, isLocked else { return }
        if await authenticator.authenticate() {
            isLocked = false
            errorMessage = nil
        } else {
            isLocked = true
            errorMessage = "Pocket Tray remains locked. Try Face ID or the device passcode again."
        }
    }
}

struct AppLockGate<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var controller: AppLockController
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if controller.isLocked {
                AppLockedView(controller: controller)
            } else {
                content()
            }
        }
        .task {
            if scenePhase == .active {
                await controller.unlock()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await controller.unlock() }
            } else {
                controller.sceneDidEnterBackground()
            }
        }
    }
}

private struct AppLockedView: View {
    @ObservedObject var controller: AppLockController

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Pocket Tray Locked")
                .font(.title.bold())
            Text("Unlock with Face ID or your device passcode.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Unlock") {
                Task { await controller.unlock() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Authenticates with the system security screen")
            if let errorMessage = controller.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("app-lock-error")
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}
