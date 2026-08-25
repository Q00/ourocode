// swift-tools-version: 5.9

import PackageDescription
import Foundation

let ghosttyRendererEnabled = ProcessInfo.processInfo.environment["OUROCODE_GHOSTTY_RENDERER_BUILD"] == "1"
let ghosttyMetalSurfaceEnabled = ProcessInfo.processInfo.environment["OUROCODE_GHOSTTY_METAL_SURFACE_BUILD"] == "1"
let metalRuntimeSourceEnabled = ProcessInfo.processInfo.environment["OUROCODE_METAL_RUNTIME_SOURCE_BUILD"] == "1"
let swiftTermCompatibilityEnabled = ProcessInfo.processInfo.environment["OUROCODE_SWIFTTERM_COMPATIBILITY_BUILD"] == "1"
let renderArchive = ProcessInfo.processInfo.environment["OUROCODE_GHOSTTY_RENDERER_ARCHIVE"]

if swiftTermCompatibilityEnabled {
    if ghosttyRendererEnabled || ghosttyMetalSurfaceEnabled || metalRuntimeSourceEnabled {
        fatalError("SwiftTerm compatibility mode cannot be combined with the Ghostty/Metal build")
    }
} else {
    if !ghosttyRendererEnabled || !ghosttyMetalSurfaceEnabled {
        fatalError("Ourocode requires the Ghostty renderer and Metal surface by default; set OUROCODE_SWIFTTERM_COMPATIBILITY_BUILD=1 only for the explicitly labelled compatibility build")
    }
    if metalRuntimeSourceEnabled && !ghosttyMetalSurfaceEnabled {
        fatalError("OUROCODE_METAL_RUNTIME_SOURCE_BUILD requires the Ghostty Metal surface")
    }
}

var desktopDependencies: [Target.Dependency] = ["SwiftTerm"]
var targets: [Target] = []
var desktopLinkerSettings: [LinkerSetting] = []
var desktopExcludedSources: [String] = []
var desktopResources: [Resource] = [
    .copy("Resources/Fonts"),
]

// Runtime shader compilation is a development-only escape hatch. Packaged
// builds link the audited metallib and do not carry Metal source in SwiftPM's
// resource bundle.
if metalRuntimeSourceEnabled {
    desktopResources.insert(.copy("Resources/OuroTerminalShaders.metal"), at: 0)
} else {
    desktopExcludedSources.append("Resources/OuroTerminalShaders.metal")
}

if ghosttyRendererEnabled {
    guard let renderArchive, renderArchive.hasPrefix("/") else {
        fatalError("OUROCODE_GHOSTTY_RENDERER_ARCHIVE must be an absolute static archive path")
    }
    targets.append(
        .systemLibrary(
            name: "COuroRender",
            path: "Sources/COuroRender"
        )
    )
    desktopDependencies.append("COuroRender")
    // Keep one ABI root in the feature-on executable even before TerminalHost
    // adopts the renderer. Otherwise release dead stripping can make a build
    // appear linked while discarding the entire static bridge.
    desktopLinkerSettings = [
        .unsafeFlags([
            renderArchive,
            "-Xlinker", "-u",
            "-Xlinker", "_ouro_render_client_new",
            "-Xlinker", "-u",
            "-Xlinker", "_ouro_split_layout_new"
        ])
    ]
}

targets.append(
    .executableTarget(
        name: "OurocodeDesktop",
        dependencies: desktopDependencies,
        path: "Sources/OurocodeDesktop",
        exclude: desktopExcludedSources,
        resources: desktopResources,
        swiftSettings: [
            ghosttyRendererEnabled ? .define("OUROCODE_GHOSTTY_RENDERER") : nil,
            ghosttyMetalSurfaceEnabled ? .define("OUROCODE_GHOSTTY_METAL_SURFACE") : nil,
            metalRuntimeSourceEnabled ? .define("OUROCODE_METAL_RUNTIME_SOURCE") : nil,
            swiftTermCompatibilityEnabled ? .define("OUROCODE_SWIFTTERM_COMPATIBILITY") : nil
        ].compactMap { $0 },
        linkerSettings: desktopLinkerSettings
    )
)

let package = Package(
    name: "OurocodeDesktop",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "OurocodeDesktop", targets: ["OurocodeDesktop"])
    ],
    dependencies: [
        // This remains a compile-time type dependency until the compatibility
        // adapter is split into its own target. The build contract above keeps
        // its terminal path unreachable unless compatibility is explicit.
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            revision: "e4f31b091b2efd81b33945ef7609141f827f2753"
        )
    ],
    targets: targets,
    swiftLanguageVersions: [.v5]
)
