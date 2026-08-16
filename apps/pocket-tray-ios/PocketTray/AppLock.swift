import AppIntents
import Foundation
import LocalAuthentication
import SwiftUI

enum AppLockPreference {
    static let key = "appLock.isEnabled"

    static var isEnabled: Bool {
        UserDefaults(suiteName: FileTrayRepository.appGroupIdentifier)?.bool(forKey: key) ?? false
    }
}

@MainActor
protocol AppLockSettings: AnyObject {
    var isAppLockEnabled: Bool { get set }
}

@MainActor
final class UserDefaultsAppLockSettings: AppLockSettings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: FileTrayRepository.appGroupIdentifier)) {
        self.defaults = defaults ?? .standard
    }

    var isAppLockEnabled: Bool {
        get { defaults.bool(forKey: AppLockPreference.key) }
        set { defaults.set(newValue, forKey: AppLockPreference.key) }
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
            guard !isLocked else { return }
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

struct AppLockSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: AppLockController
    let tray: Tray
    @State private var isChangingSetting = false
    @State private var storageReport: TrayStorageReport?
    @State private var storageError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Shortcuts") {
                    ShortcutsLink()
                    Text("Use Pocket Tray actions from Shortcuts, Siri, Spotlight, the Action button, or Home Screen widgets.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Storage") {
                    if let storageReport {
                        LabeledContent("Pocket Tray usage") {
                            Text(storageReport.totalBytes, format: .byteCount(style: .file))
                        }
                        if storageReport.exceedsWarningThreshold {
                            Label(
                                "Usage is over 500 MB. Pocket Tray will not delete or compress your objects automatically.",
                                systemImage: "externaldrive.badge.exclamationmark"
                            )
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("storage-threshold-warning")
                        }
                        if storageReport.unavailableAssetCount > 0 {
                            Label(
                                "\(storageReport.unavailableAssetCount) original \(storageReport.unavailableAssetCount == 1 ? "file is" : "files are") missing or damaged. Re-capture the original or delete the affected object.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("unavailable-assets-warning")
                        }
                        if storageReport.recoveredMetadata {
                            Label(
                                "Pocket Tray recovered its saved index from the latest backup.",
                                systemImage: "checkmark.arrow.trianglehead.counterclockwise"
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("metadata-recovery-notice")
                        }
                    } else if let storageError {
                        Label(storageError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else {
                        ProgressView("Calculating usage…")
                    }
                    Button("Refresh Storage Status") { Task { await loadStorageReport() } }
                }
                Section("Privacy") {
                    Toggle(
                        "Require Face ID or Passcode",
                        isOn: Binding(
                            get: { controller.isEnabled },
                            set: { isEnabled in updateAppLock(isEnabled) }
                        )
                    )
                    .disabled(isChangingSetting)
                    Text("When enabled, Pocket Tray locks after you leave the app. Authentication uses Apple's system screen and supports the device passcode fallback.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let errorMessage = controller.errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("app-lock-setting-error")
                    }
                }
            }
            .task { await loadStorageReport() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func loadStorageReport() async {
        do {
            storageReport = try await tray.storageReport()
            storageError = nil
        } catch {
            storageError = error.localizedDescription
        }
    }

    private func updateAppLock(_ isEnabled: Bool) {
        isChangingSetting = true
        Task {
            await controller.setEnabled(isEnabled)
            isChangingSetting = false
        }
    }
}
