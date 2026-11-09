// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "RummikubKit",
  platforms: [.iOS(.v27), .macOS(.v27)],
  products: [
    .library(name: "RummikubKit", targets: ["RummikubKit"])
  ],
  targets: [
    .target(name: "RummikubKit"),
    .executableTarget(name: "bench", dependencies: ["RummikubKit"]),
    .executableTarget(name: "check", dependencies: ["RummikubKit"]),
    .executableTarget(name: "fill", dependencies: ["RummikubKit"]),
    .executableTarget(name: "score", dependencies: ["RummikubKit"]),
    .executableTarget(name: "words"),
    .executableTarget(name: "scene"),
    .testTarget(name: "RummikubKitTests", dependencies: ["RummikubKit"]),
  ]
)
