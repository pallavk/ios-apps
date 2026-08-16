import Foundation

enum ControlCaptureHandoff {
    private static let appGroupIdentifier = "group.com.pallavk.PocketTray"
    private static let requestKey = "controlCapture.requested"

    static func requestCapture() {
        UserDefaults(suiteName: appGroupIdentifier)?.set(true, forKey: requestKey)
    }

    static func consumeCaptureRequest() -> Bool {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return false }
        let wasRequested = defaults.bool(forKey: requestKey)
        if wasRequested {
            defaults.set(false, forKey: requestKey)
        }
        return wasRequested
    }
}
