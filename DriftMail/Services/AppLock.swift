import LocalAuthentication
import Observation
import SwiftUI

/// Optional Face ID / passcode lock. When on, DriftMail locks whenever it leaves the
/// screen, hides its content in the app switcher, and unlocks with Face ID (or the
/// device passcode as a fallback).
@MainActor
@Observable
final class AppLock {
    static let shared = AppLock()
    static let enabledKey = "requireFaceID"

    private(set) var isLocked: Bool
    @ObservationIgnored private var authenticating = false

    private init() {
        isLocked = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    func lock() {
        if isEnabled { isLocked = true }
    }

    /// Asks for Face ID / passcode. Stays locked if the person cancels.
    func unlock() async {
        guard isLocked, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        let context = LAContext()
        var error: NSError?
        // No passcode on the device: there is nothing to unlock with, so don't trap the user.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isLocked = false
            return
        }
        if (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your mail")) == true {
            isLocked = false
        }
    }

    /// Confirms the person can authenticate before the lock is turned on.
    static func confirmCanEnable() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                  localizedReason: "Turn on the lock for DriftMail")) == true
    }
}

/// Covers the app while locked, and in the app switcher when the lock is on.
struct LockScreen: View {
    var body: some View {
        ZStack {
            Theme.softDrift.ignoresSafeArea()
            VStack(spacing: 18) {
                DriftLogo(size: 84)
                Text("DriftMail is locked")
                    .font(.title3.weight(.semibold))
                Button {
                    Task { await AppLock.shared.unlock() }
                } label: {
                    Label("Unlock", systemImage: "faceid")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
