// swift-tools-version:5.9
import PackageDescription

// libmtp comes from Homebrew (`brew install libmtp`); build-app.sh copies it into the .app.
let package = Package(
    name: "PhoneFiles",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CMTP", path: "Sources/CMTP"),
        .executableTarget(
            name: "PhoneFiles",
            dependencies: ["CMTP"],
            path: "Sources/PhoneFiles",
            swiftSettings: [.unsafeFlags(["-Xcc", "-I/opt/homebrew/include"])],
            linkerSettings: [.unsafeFlags(["-L/opt/homebrew/lib"])]
        ),
    ]
)
