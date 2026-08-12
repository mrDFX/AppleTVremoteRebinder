// swift-tools-version: 5.9
// NOTE: This package does not include MultitouchSupport.framework (private API).
// Use build.sh for full trackpad support.

import PackageDescription

let package = Package(
    name: "AppleTVremoteRebinder",
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "AppleTVremoteRebinder", targets: ["AppleTVremoteRebinder"])
    ],
    targets: [
        .executableTarget(
            name: "AppleTVremoteRebinder",
            path: ".",
            sources: [
                "main.swift",
                "SiriRemoteApp.swift",
                "MenuBarManager.swift",
                "RemoteDetector.swift",
                "RemoteInputHandler.swift",
                "CursorController.swift",
                "MediaController.swift",
                "MediaKeyInterceptor.swift",
                "TouchHandler.swift",
                "SystemVolume.swift"
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit")
            ]
        )
    ]
)
