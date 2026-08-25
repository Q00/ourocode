import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum PermissionOnboardingPolicyFixture {
    static func main() {
        require(
            PermissionOnboardingPolicy.shouldPresent(
                arguments: ["Ourocode", "--onboarding"],
                bundlePath: "/private/tmp/Ourocode.app",
                alreadyPresented: true
            ),
            "explicit onboarding did not override prior presentation"
        )
        require(
            PermissionOnboardingPolicy.shouldPresent(
                arguments: ["Ourocode"],
                bundlePath: "/Applications/Ourocode.app",
                alreadyPresented: false
            ),
            "installed final app did not receive first-launch onboarding"
        )
        require(
            !PermissionOnboardingPolicy.shouldPresent(
                arguments: ["Ourocode"],
                bundlePath: "/private/tmp/Ourocode.app",
                alreadyPresented: false
            ),
            "temporary development build claimed installer onboarding"
        )
        require(
            !PermissionOnboardingPolicy.shouldPresent(
                arguments: ["Ourocode"],
                bundlePath: "/Applications/Ourocode.app",
                alreadyPresented: true
            ),
            "onboarding repeated after completion"
        )
        print("PASS: permission onboarding targets the final app and remains one-time unless explicit")
    }
}
