import AppKit
import CoreText

/// SwiftPM's generated `Bundle.module` lookup is correct for a raw executable,
/// but it searches beside `Bundle.main.bundleURL` after that executable is put
/// in a macOS app. Signed app resources belong in `Contents/Resources`, so use
/// the packaged bundle there first and retain `Bundle.module` only for direct
/// `swift run` and fixture builds.
enum OurocodeResourceBundle {
    #if SWIFT_PACKAGE
    static let shared: Bundle = {
        if let resources = Bundle.main.resourceURL,
           let packaged = Bundle(
             url: resources.appendingPathComponent(
               "OurocodeDesktop_OurocodeDesktop.bundle",
               isDirectory: true
             )
           ) {
            return packaged
        }
        // A packaged app must never reach back into SwiftPM's build scratch.
        // That can make a broken copy look healthy on the build machine and
        // then crash after distribution. Direct `swift run` has no `.app`
        // bundle and is the only mode allowed to use Bundle.module.
        if Bundle.main.bundleURL.pathExtension == "app" {
            preconditionFailure(
              "Packaged Ourocode is missing OurocodeDesktop_OurocodeDesktop.bundle"
            )
        }
        return Bundle.module
    }()
    #else
    static let shared = Bundle.main
    #endif
}

/// Registers one deterministic, fixed-pitch terminal face for this process.
/// Keeping registration process-scoped avoids changing the user's font
/// library while making Powerline/Nerd glyphs available before `.zshrc`
/// renders the first prompt.
enum BundledTerminalFont {
    static let postScriptName = "MesloLGSNFM-Regular"

    @discardableResult
    static func register() -> Bool {
        if NSFont(name: postScriptName, size: OuroTheme.defaultTerminalFontSize) != nil {
            return true
        }
        guard let url = resourceURL else {
            NSLog("Ourocode: bundled terminal font resource is missing")
            return false
        }
        var registrationError: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(
            url as CFURL,
            .process,
            &registrationError
        )
        guard registered || NSFont(name: postScriptName, size: 16) != nil else {
            let detail = registrationError?.takeRetainedValue().localizedDescription
                ?? "unknown CoreText error"
            NSLog("Ourocode: bundled terminal font could not be registered: %@", detail)
            return false
        }
        return true
    }

    private static var resourceURL: URL? {
        #if SWIFT_PACKAGE
        OurocodeResourceBundle.shared.url(
            forResource: "MesloLGSNerdFontMono-Regular",
            withExtension: "ttf",
            subdirectory: "Fonts"
        )
        #else
        nil
        #endif
    }
}
