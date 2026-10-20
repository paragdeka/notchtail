// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "notchtail",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "notchtail", targets: ["NotchStatus"])],
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
