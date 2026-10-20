// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotchStatus",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "NotchStatus", targets: ["NotchStatus"])],
    targets: [
        .executableTarget(
            name: "NotchStatus",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreServices"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("Security"),
            ]
        )
    ]
)
