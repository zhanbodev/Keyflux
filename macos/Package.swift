// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "KeyfluxApp",
  platforms: [.macOS(.v13)],
  targets: [.executableTarget(name: "KeyfluxApp", resources: [.copy("Resources/Keyboards")])]
)
