// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AccountDock", platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "AccountDock"),
              .testTarget(name: "AccountDockTests", dependencies: ["AccountDock"], path: "tests/AccountDockTests") ])
