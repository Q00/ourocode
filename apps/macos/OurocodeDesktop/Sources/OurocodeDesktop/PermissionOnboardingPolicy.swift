import Foundation

enum PermissionOnboardingPolicy {
    static let presentedKey = "permissionOnboarding.presented.v1"

    static func shouldPresent(
        arguments: [String],
        bundlePath: String,
        alreadyPresented: Bool
    ) -> Bool {
        if arguments.contains("--onboarding") { return true }
        guard !alreadyPresented else { return false }
        let normalized = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        return normalized == "/Applications/Ourocode.app"
            || normalized.hasPrefix("/Applications/Ourocode.app/")
    }
}
