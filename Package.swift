// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "EchoGuide", platforms: [.macOS(.v14)], products: [.executable(name: "EchoGuide", targets: ["EchoGuide"])], targets: [.executableTarget(name: "EchoGuide"), .testTarget(name: "EchoGuideTests", dependencies: ["EchoGuide"])])
