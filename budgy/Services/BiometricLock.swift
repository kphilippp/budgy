import Foundation
import LocalAuthentication
import Observation

/// Face ID gate shown on launch and when returning from the background.
@Observable
final class BiometricLock {
    var isUnlocked = false

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.faceIDEnabled) }

    func lockIfNeeded() {
        if isEnabled { isUnlocked = false }
    }

    func unlock() async {
        guard isEnabled else {
            isUnlocked = true
            return
        }
        let context = LAContext()
        var error: NSError?
        // Falls back to the device passcode if Face ID isn't available.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isUnlocked = true
            return
        }
        let success = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Budgy")) ?? false
        isUnlocked = success
    }
}
