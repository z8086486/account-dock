// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AccountDock", platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [.executableTarget(name: "AccountDock", dependencies: [.product(name: "Sparkle", package: "Sparkle")], resources: [.copy("Resources/release.json")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
              .testTarget(name: "AccountDockTests", dependencies: ["AccountDock"], path: "tests/AccountDockTests") ])
